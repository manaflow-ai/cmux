public import Foundation

/// The byte-level view of one accepted lane the tunnel host needs, so the
/// host can be tested without QUIC.
public protocol IrxTunnelLane: Sendable {
    var descriptor: IrxLaneDescriptor { get }
    func readRaw(maximumByteCount: Int) async throws -> Data?
    func write(_ data: Data) async throws
    func writeFrame(_ value: some Encodable & Sendable) async throws
    /// Half-close our sending side.
    func finish() async
    /// Abort both halves.
    func abort() async
}

extension IrxLaneStream: IrxTunnelLane {
    public func readRaw(maximumByteCount: Int) async throws -> Data? {
        try await reader.readRaw(maximumByteCount: maximumByteCount)
    }

    public func write(_ data: Data) async throws {
        try await writer.write(data)
    }

    public func writeFrame(_ value: some Encodable & Sendable) async throws {
        try await writer.writeControlFrame(value)
    }

    public func finish() async {
        await writer.finish()
    }

    public func abort() async {
        await writer.reset(errorCode: 3)
        await reader.stop(errorCode: 3)
    }
}

/// Serves the phone browser tunnel for ONE admitted phone connection.
///
/// Security posture (see `IrxTunnelDestinationPolicy` for destinations):
/// - Every open re-checks `isAuthorized`, the same live check that keeps the
///   admitted session itself alive (list-auth entry fresh, not revoked,
///   pairing enabled), so a revoked phone cannot open new tunnels.
/// - Concurrent tunnels and the open rate are capped per connection.
/// - `stop()` (connection exit) aborts every tunnel; nothing outlives the
///   phone's connection.
/// - The journal records destination scope, port, and outcome, never host
///   names or payload bytes.
public actor IrxTunnelHost {
    public struct Limits: Sendable {
        public var maximumConcurrentTunnels: Int
        /// Token bucket: `openBurst` opens at once, refilled at `opensPerSecond`.
        public var openBurst: Double
        public var opensPerSecond: Double
        public var connectTimeout: Duration
        /// Largest chunk read from either side before it is written to the
        /// other; with one in flight per direction this bounds memory.
        public var chunkByteCount: Int

        public init(
            maximumConcurrentTunnels: Int = 32,
            openBurst: Double = 64,
            opensPerSecond: Double = 32,
            connectTimeout: Duration = .seconds(10),
            chunkByteCount: Int = 64 * 1024
        ) {
            self.maximumConcurrentTunnels = maximumConcurrentTunnels
            self.openBurst = openBurst
            self.opensPerSecond = opensPerSecond
            self.connectTimeout = connectTimeout
            self.chunkByteCount = chunkByteCount
        }
    }

    private let limits: Limits
    private let connector: any IrxTunnelConnecting
    private let policy: @Sendable () -> IrxTunnelDestinationPolicy
    private let isAuthorized: @Sendable () -> Bool
    private let listPorts: @Sendable () async -> [IrxListeningPort]
    private let journal: IrxJournal?
    private let now: @Sendable () -> ContinuousClock.Instant

    private var activeTunnels = 0
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    public init(
        limits: Limits = Limits(),
        connector: any IrxTunnelConnecting = IrxTunnelNetworkConnector(),
        policy: @escaping @Sendable () -> IrxTunnelDestinationPolicy,
        isAuthorized: @escaping @Sendable () -> Bool,
        listPorts: @escaping @Sendable () async -> [IrxListeningPort] = {
            await Task.detached(priority: .utility) { IrxListeningPortScanner.loopbackListeningPorts() }.value
        },
        journal: IrxJournal? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.limits = limits
        self.connector = connector
        self.policy = policy
        self.isAuthorized = isAuthorized
        self.listPorts = listPorts
        self.journal = journal
        self.now = now
        tokens = limits.openBurst
        lastRefill = now()
    }

    /// Number of tunnels currently relaying (for tests and diagnostics).
    public var activeTunnelCount: Int { activeTunnels }

    /// Takes ownership of a `tcpConnect` or `listeningPorts` lane and serves
    /// it in the background. Returns immediately.
    public func accept(_ lane: any IrxTunnelLane) {
        guard !stopped else {
            Task { await lane.abort() }
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            switch lane.descriptor.lane {
            case .tcpConnect:
                await self.serveConnect(lane)
            case .listeningPorts:
                await self.serveListeningPorts(lane)
            default:
                await lane.abort()
            }
            await self.finished(id)
        }
        tasks[id] = task
    }

    /// Aborts every tunnel and refuses new ones (the connection ended).
    public func stop() {
        stopped = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    /// Waits until every accepted lane has been served (tests).
    public func drain() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    private func finished(_ id: UUID) {
        tasks[id] = nil
    }

    // MARK: Admission

    private func takeOpenToken() -> Bool {
        let current = now()
        let elapsed = (current - lastRefill).seconds
        lastRefill = current
        tokens = min(limits.openBurst, tokens + elapsed * limits.opensPerSecond)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    private func reserveTunnel() -> Bool {
        guard !stopped, activeTunnels < limits.maximumConcurrentTunnels else { return false }
        activeTunnels += 1
        return true
    }

    private func releaseTunnel() {
        activeTunnels = max(0, activeTunnels - 1)
    }

    // MARK: tcpConnect

    private func serveConnect(_ lane: any IrxTunnelLane) async {
        let port = lane.descriptor.port ?? 0
        guard isAuthorized() else {
            await reply(.denied, on: lane, scope: "unauthorized", port: port)
            return
        }
        guard takeOpenToken(), reserveTunnel() else {
            await reply(.busy, on: lane, scope: "limit", port: port)
            return
        }
        defer { releaseTunnel() }
        let policy = policy()
        let targets: [IrxTunnelIPAddress]
        switch policy.evaluate(host: lane.descriptor.host ?? "", port: port) {
        case .deny:
            await reply(.denied, on: lane, scope: "policy", port: port)
            return
        case .connect(let addresses):
            targets = addresses
        case .resolve(let name):
            let resolved = await connector.resolve(host: name)
            guard !resolved.isEmpty else {
                await reply(.unresolved, on: lane, scope: "remote", port: port)
                return
            }
            targets = policy.filterResolved(resolved)
            guard !targets.isEmpty else {
                await reply(.denied, on: lane, scope: "resolved-policy", port: port)
                return
            }
        }
        let scope = targets.allSatisfy { $0.scope == .loopback } ? "loopback" : "remote"
        let channel: any IrxTunnelByteChannel
        do {
            channel = try await connector.connect(to: targets, port: port, timeout: limits.connectTimeout)
        } catch {
            await reply(error.status, on: lane, scope: scope, port: port)
            return
        }
        guard !Task.isCancelled else {
            channel.cancel()
            await lane.abort()
            return
        }
        do {
            try await lane.writeFrame(IrxTunnelOpenReply(status: .connected))
        } catch {
            channel.cancel()
            await lane.abort()
            return
        }
        journal?.record("host-tunnel", "opened", ["scope": scope, "port": String(port)])
        let clean = await Self.relay(lane: lane, channel: channel, chunkByteCount: limits.chunkByteCount)
        journal?.record(
            "host-tunnel", "closed",
            ["scope": scope, "port": String(port), "result": clean ? "clean" : "aborted"]
        )
    }

    private func reply(
        _ status: IrxTunnelOpenReply.Status,
        on lane: any IrxTunnelLane,
        scope: String,
        port: Int
    ) async {
        journal?.record(
            "host-tunnel", "refused",
            ["scope": scope, "port": String(port), "status": status.rawValue]
        )
        try? await lane.writeFrame(IrxTunnelOpenReply(status: status))
        await lane.finish()
    }

    /// Copies bytes both ways until both sides finish (half-closes pass
    /// through) or either fails (both are aborted). One chunk in flight per
    /// direction: each read waits for the previous write, so a slow reader
    /// on one side backpressures the writer on the other through QUIC and
    /// TCP flow control instead of buffering here.
    static func relay(
        lane: any IrxTunnelLane,
        channel: any IrxTunnelByteChannel,
        chunkByteCount: Int
    ) async -> Bool {
        await withTaskCancellationHandler {
            let clean = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask {
                    do {
                        while let chunk = try await lane.readRaw(maximumByteCount: chunkByteCount) {
                            try Task.checkCancellation()
                            try await channel.send(chunk)
                        }
                        await channel.finishSending()
                        return true
                    } catch {
                        return false
                    }
                }
                group.addTask {
                    do {
                        while let chunk = try await channel.receive(maximumByteCount: chunkByteCount) {
                            try Task.checkCancellation()
                            try await lane.write(chunk)
                        }
                        await lane.finish()
                        return true
                    } catch {
                        return false
                    }
                }
                var clean = true
                for await directionClean in group where !directionClean {
                    if clean {
                        clean = false
                        channel.cancel()
                        await lane.abort()
                    }
                }
                return clean
            }
            channel.cancel()
            return clean
        } onCancel: {
            channel.cancel()
            Task { await lane.abort() }
        }
    }

    // MARK: listeningPorts

    private func serveListeningPorts(_ lane: any IrxTunnelLane) async {
        guard isAuthorized(), takeOpenToken() else {
            await lane.abort()
            return
        }
        let ports = await listPorts()
        let reply = IrxListeningPortsReply(ports: ports, allowsNonLoopbackHosts: policy().allowsNonLoopbackHosts)
        do {
            try await lane.writeFrame(reply)
            await lane.finish()
        } catch {
            await lane.abort()
        }
        journal?.record("host-tunnel", "listed-ports", ["count": String(ports.count)])
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
