import CmuxLink
import CmuxLinkDirect
import Foundation

/// Configuration for the standalone Mac-side F2 service. The service is
/// intentionally opt-in and development-only; callers should pass the
/// paired phone's public key rather than `allowAny` on a shared network.
public struct BenchSplitServerConfiguration: Sendable, Hashable {
    public var hostID: String
    /// Address the client should dial. This is metadata; `nil` listens on all
    /// interfaces and is useful when advertising a LAN address.
    public var advertisedAddress: String
    public var localAddress: String?
    public var port: UInt16
    public var allowAnyDevice: Bool
    public var allowedDevices: Set<DirectPublicKey>
    public var bulkRecordBytes: Int

    public init(
        hostID: String = "cmux-link-bench",
        advertisedAddress: String = "127.0.0.1",
        localAddress: String? = "127.0.0.1",
        port: UInt16 = 0,
        allowAnyDevice: Bool = false,
        allowedDevices: Set<DirectPublicKey> = [],
        bulkRecordBytes: Int = 64 * 1024
    ) {
        self.hostID = hostID
        self.advertisedAddress = advertisedAddress
        self.localAddress = localAddress
        self.port = port
        self.allowAnyDevice = allowAnyDevice
        self.allowedDevices = allowedDevices
        self.bulkRecordBytes = max(1, bulkRecordBytes)
    }
}

private actor BenchDeviceAuthorizer: DirectAuthorizer {
    let allowAny: Bool
    let allowed: Set<DirectPublicKey>

    init(allowAny: Bool, allowed: Set<DirectPublicKey>) {
        self.allowAny = allowAny
        self.allowed = allowed
    }

    func authorize(device: DirectPublicKey) async -> Bool {
        allowAny || allowed.contains(device)
    }
}

/// A Mac-side source/echo service for split runs. It deliberately uses the
/// same `LinkHost` and channel descriptors as the in-process runner, so the
/// iOS client measures the real direct carrier and session implementation.
public actor BenchSplitServer {
    public let identity: DirectIdentity
    public let configuration: BenchSplitServerConfiguration

    private var acceptor: DirectAcceptor?
    private var host: LinkHost?
    private var sessionTask: Task<Void, Never>?
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var channelTasks: [UUID: Task<Void, Never>] = [:]
    private var activeSessions: Set<UUID> = []
    private var started = false
    private var stopped = false

    public init(identity: DirectIdentity = DirectIdentity(), configuration: BenchSplitServerConfiguration = .init()) {
        self.identity = identity
        self.configuration = configuration
    }

    /// Starts listening and returns the descriptor a phone can import.
    public func start() async throws -> BenchServeDescriptor {
        guard !started, !stopped else { throw BenchSplitError.server("server already stopped") }
        guard !configuration.hostID.isEmpty, !configuration.advertisedAddress.isEmpty else {
            throw BenchSplitError.invalidDescriptor("server address")
        }
        guard (1...(256 * 1024 - LinkFrame.dataOverhead)).contains(configuration.bulkRecordBytes) else {
            throw BenchSplitError.invalidDescriptor("bulk record size")
        }
        // Reserve the actor before the first suspension. A concurrent stop()
        // therefore always owns and closes the listener being started.
        started = true
        let authorizer = BenchDeviceAuthorizer(
            allowAny: configuration.allowAnyDevice,
            allowed: configuration.allowedDevices
        )
        let acceptor = DirectAcceptor(
            identity: identity,
            hostID: configuration.hostID,
            configuration: DirectListenConfiguration(port: configuration.port, localAddress: configuration.localAddress),
            authorizer: authorizer
        )
        self.acceptor = acceptor
        do {
            let port = try await acceptor.start()
            guard !stopped else {
                await acceptor.stop()
                self.acceptor = nil
                started = false
                throw CancellationError()
            }
            let host = LinkHost(acceptor: acceptor, configuration: LinkConfiguration(
                handshakeTimeout: .seconds(10), maxConnectAttempts: 4,
                maxPendingIncomingChannels: 64, maxPendingSessions: 16, degradedRTT: nil
            ))
            self.host = host
            await host.start()
            guard !stopped else {
                await host.close()
                await acceptor.stop()
                self.host = nil
                self.acceptor = nil
                started = false
                throw CancellationError()
            }

            let sessions = await host.sessions()
            sessionTask = Task { [weak self] in
                for await session in sessions {
                    guard let self else { return }
                    await self.serve(session)
                }
            }
            return BenchServeDescriptor(
                hostID: configuration.hostID,
                address: configuration.advertisedAddress,
                port: port,
                hostKey: identity.publicKey,
                carriers: [.direct],
                bulkRecordBytes: configuration.bulkRecordBytes
            )
        } catch {
            await acceptor.stop()
            self.acceptor = nil
            self.host = nil
            started = false
            throw error
        }
    }

    /// Stops the listener and all source/echo tasks. The call is idempotent.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        sessionTask?.cancel()
        sessionTask = nil
        for task in sessionTasks.values { task.cancel() }
        sessionTasks.removeAll()
        for task in channelTasks.values { task.cancel() }
        channelTasks.removeAll()
        activeSessions.removeAll()
        await host?.close()
        await acceptor?.stop()
        host = nil
        acceptor = nil
    }

    private func serve(_ session: LinkSession) {
        guard !stopped, activeSessions.count < 16 else {
            Task { await session.close() }
            return
        }
        let sessionID = session.sessionID
        activeSessions.insert(sessionID)
        let taskID = UUID()
        let channels = Task { [weak self] in
            let incoming = await session.incomingChannels()
            for await channel in incoming {
                guard let self else { return }
                await self.installChannel(channel)
            }
            await self?.removeSession(sessionID: sessionID, taskID: taskID)
        }
        sessionTasks[taskID] = channels
    }

    private func installChannel(_ channel: LinkChannel) {
        guard !stopped, channelTasks.count < 64 else {
            Task { await channel.close() }
            return
        }
        let id = UUID()
        channelTasks[id] = Task { [weak self] in
            await self?.serve(channel)
            await self?.removeChannel(id)
        }
    }

    private func removeChannel(_ id: UUID) {
        channelTasks.removeValue(forKey: id)
    }

    private func removeSession(sessionID: UUID, taskID: UUID) {
        activeSessions.remove(sessionID)
        sessionTasks.removeValue(forKey: taskID)
    }

    private func serve(_ channel: LinkChannel) async {
        switch channel.stream {
        case "bench/echo":
            for await event in channel.events {
                guard case let .message(message) = event else { continue }
                _ = try? await channel.send(message.payload)
            }
        case "bench/flood":
            await source(channel, bytes: 4 * 1024)
        case "bench/bulk", "bench/bulk-bg":
            await source(channel, bytes: configuration.bulkRecordBytes)
        default:
            await channel.close()
        }
    }

    private func source(_ channel: LinkChannel, bytes: Int) async {
        let payload = Data(count: max(1, bytes))
        while !Task.isCancelled {
            do {
                try await channel.send(payload)
            } catch {
                await channel.close()
                return
            }
        }
    }
}
