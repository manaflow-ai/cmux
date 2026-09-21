import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

/// Owns outgoing control sessions while borrowing the Mac's single registered endpoint.
actor DeviceIrxClient {
    typealias ContextProvider = @Sendable () async throws -> DeviceIrxClientContext

    private enum Authorization {
        case waiting
        case verified(bindingID: String, generation: Int)
        case closing
    }

    private struct Session {
        let owner: UUID
        let instance: SurfaceDeviceInstanceID
        let engine: IrxPeerEngine
        var eventsClaimed = false
        var authorization: Authorization = .waiting
    }

    private let context: ContextProvider
    private let journal: IrxJournal
    private let permissionNow: @Sendable () -> Date
    private var sessions: [String: Session] = [:]
    private var stopped = false
    private var directoryObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var publishedDiscovery: DiscoveryState?

    /// Only facts used by outgoing discovery invalidate its list. This Mac's
    /// hosting metadata, inbound grants and ticket refreshes do not change it.
    private struct DiscoveryState: Equatable {
        let identity: V2Identity
        let devices: [V2DeviceRecord]
        let permissionExpiresAt: Int
        let relayURLs: [String]
        let revoked: Bool

        init?(cache: V2CachedState?) {
            guard let cache, let directory = cache.directory else { return nil }
            identity = cache.identity
            devices = directory.devices.filter {
                $0.descriptor.identity.deviceID.lowercased() != cache.identity.deviceID.lowercased()
                    || $0.descriptor.identity.buildTag != cache.identity.buildTag
            }.sorted { $0.deviceRecordID < $1.deviceRecordID }
            permissionExpiresAt = directory.permissionExpiresAt
            relayURLs = directory.relayURLs
            revoked = cache.authorityRevoked
        }
    }

    init(context: @escaping ContextProvider, journal: IrxJournal) {
        self.context = context
        self.journal = journal
        let wall = Date().timeIntervalSince1970
        let monotonic = ContinuousClock.now
        permissionNow = {
            let elapsed = monotonic.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            return Date(timeIntervalSince1970: max(Date().timeIntervalSince1970, wall + max(0, seconds)))
        }
    }

    /// Discovery reads the same complete v2 directory that authorizes outgoing control.
    func discoverMacs() async throws -> [DeviceDiscoveredMac] {
        let borrowed = try await context()
        guard !stopped, await borrowed.isCurrent() else { throw DeviceLinkError.notConnected }
        let cache = await borrowed.control.snapshot().cache
        return Self.displayBindings(cache: cache, now: permissionNow())
    }

    /// A pushed account-directory revision triggers a discovery refresh without polling.
    func directoryChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !stopped else { continuation.finish(); return stream }
        directoryObservers[id] = continuation
        continuation.yield(())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDirectoryObserver(id) }
        }
        return stream
    }

    private func removeDirectoryObserver(_ id: UUID) {
        directoryObservers[id] = nil
    }

    func transport(
        for request: CmxByteTransportRequest,
        instance: SurfaceDeviceInstanceID
    ) async throws -> any CmxByteTransport {
        let endpoint = try Self.endpoint(for: request, instance: instance)
        let borrowed = try await context()
        guard !stopped, await borrowed.isCurrent(), sessions[endpoint] == nil else { throw DeviceLinkError.notConnected }
        let owner = UUID()
        let context = context
        let journal = journal
        let permissionNow = permissionNow
        let engine = IrxPeerEngine(journal: journal, label: "mac-device") { [weak self] in
            try await Self.dial(
                endpoint: endpoint, instance: instance,
                context: context, journal: journal, now: permissionNow,
                recordBinding: { [weak self] binding in
                    await self?.record(binding: binding, endpoint: endpoint, owner: owner) == true
                }
            )
        }
        sessions[endpoint] = Session(owner: owner, instance: instance, engine: engine)
        return IrxControlByteTransport(
            closeCode: .userRequested,
            establish: { [weak self] in
                do {
                    let session = try await engine.ensureSession(trigger: "mac-control")
                    return (session.connection, session.control)
                } catch {
                    await self?.release(endpoint: endpoint, owner: owner)
                    throw error
                }
            },
            onClose: { [weak self] _, _, _ in await self?.release(endpoint: endpoint, owner: owner) },
            permitsIO: { [weak self] in
                guard await borrowed.isCurrent(), let self else { return false }
                return await self.permitsIO(context: borrowed, endpoint: endpoint, owner: owner)
            }
        )
    }

    func events(
        for request: CmxByteTransportRequest,
        instance: SurfaceDeviceInstanceID
    ) async throws -> CmxIndependentEventByteStream {
        let endpoint = try Self.endpoint(for: request, instance: instance)
        guard !stopped, var entry = sessions[endpoint], entry.instance == instance,
              !entry.eventsClaimed else { throw DeviceLinkError.notConnected }
        entry.eventsClaimed = true
        sessions[endpoint] = entry
        let owner = entry.owner
        // The claim is taken before suspending so a concurrent caller cannot
        // also accept the events lane. Nothing has been accepted yet when the
        // context or the session fails, so hand the claim back: the next
        // caller must be able to retry instead of finding the lane held
        // until the whole session is released.
        let borrowed: DeviceIrxClientContext
        let session: IrxClientSession
        do {
            borrowed = try await context()
            session = try await entry.engine.ensureSession(trigger: "mac-events")
            guard !stopped, sessions[endpoint]?.owner == owner else { throw DeviceLinkError.notConnected }
        } catch {
            releaseEventsClaim(endpoint: endpoint, owner: owner)
            throw error
        }
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    guard let (descriptor, reader) = try await session.connection.acceptUniLane(),
                          descriptor.lane == .events else { throw DeviceLinkError.notConnected }
                    while let chunk = try await reader.readRaw() {
                        try Task.checkCancellation()
                        guard await borrowed.isCurrent(),
                              await self.permitsIO(context: borrowed, endpoint: endpoint, owner: owner) else {
                            await self.release(endpoint: endpoint, owner: owner)
                            throw DeviceLinkError.notConnected
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func stop() async {
        stopped = true
        for observer in directoryObservers.values { observer.finish() }
        directoryObservers.removeAll()
        let previous = Array(sessions.values)
        sessions.removeAll()
        for session in previous { await session.engine.stop() }
    }

    func enforce(_ cache: V2CachedState?) async {
        let revoked = sessions.filter { endpoint, entry in
            guard let cache, let peer = try? IrxMacPeerAuthorization(
                deviceID: entry.instance.deviceID, tag: entry.instance.tag, endpointID: endpoint
            ).resolve(cache: cache, localIdentity: cache.identity, now: permissionNow()) else { return true }
            switch entry.authorization {
            case .waiting: return false
            case .verified: return !isAuthorized(peer, endpoint: endpoint, owner: entry.owner)
            case .closing: return false
            }
        }
        for (endpoint, entry) in revoked { await release(endpoint: endpoint, owner: entry.owner) }
        let discovery = DiscoveryState(cache: cache)
        guard publishedDiscovery != discovery else { return }
        publishedDiscovery = discovery
        for observer in directoryObservers.values { observer.yield(()) }
    }

    private func record(binding: V2DeviceRecord, endpoint: String, owner: UUID) -> Bool {
        guard !stopped, var entry = sessions[endpoint], entry.owner == owner else { return false }
        if case .closing = entry.authorization { return false }
        entry.authorization = .verified(bindingID: binding.deviceRecordID, generation: binding.descriptor.identityGeneration)
        sessions[endpoint] = entry
        return true
    }

    private func permitsIO(context: DeviceIrxClientContext, endpoint: String, owner: UUID) async -> Bool {
        guard let entry = sessions[endpoint], entry.owner == owner else { return false }
        let cache = await context.control.snapshot().cache
        guard let peer = try? IrxMacPeerAuthorization(
            deviceID: entry.instance.deviceID, tag: entry.instance.tag, endpointID: endpoint
        ).resolve(cache: cache, localIdentity: context.localDevice.descriptor.identity, now: permissionNow()) else { return false }
        return isAuthorized(peer, endpoint: endpoint, owner: owner)
    }

    private func isAuthorized(_ peer: V2DeviceRecord, endpoint: String, owner: UUID) -> Bool {
        guard !stopped, let session = sessions[endpoint], session.owner == owner,
              case let .verified(bindingID, generation) = session.authorization else { return false }
        return peer.descriptor.identity.deviceID.lowercased() == session.instance.deviceID
            && peer.descriptor.identity.buildTag == session.instance.tag
            && peer.deviceRecordID == bindingID && peer.descriptor.identityGeneration == generation
    }

    private func releaseEventsClaim(endpoint: String, owner: UUID) {
        guard var session = sessions[endpoint], session.owner == owner else { return }
        session.eventsClaimed = false
        sessions[endpoint] = session
    }

    private func release(endpoint: String, owner: UUID) async {
        guard var session = sessions[endpoint], session.owner == owner else { return }
        if case .closing = session.authorization { return }
        session.authorization = .closing
        sessions[endpoint] = session
        // Keep the slot claimed until the old QUIC session has closed.
        await session.engine.stop()
        if sessions[endpoint]?.owner == owner { sessions[endpoint] = nil }
    }

    private static func endpoint(
        for request: CmxByteTransportRequest,
        instance: SurfaceDeviceInstanceID
    ) throws -> String {
        try request.route.validate()
        guard request.route.kind == .iroh,
              request.authorizationMode == .transportAdmission,
              request.expectedPeerDeviceID?.lowercased() == instance.deviceID,
              case let .peer(identity, _) = request.route.endpoint else {
            throw DeviceLinkError.identityMismatch
        }
        return identity.endpointID
    }

    /// Directory permission selects the exact peer and its relay coordinates.
    private static func dial(
        endpoint: String,
        instance: SurfaceDeviceInstanceID,
        context provider: ContextProvider,
        journal: IrxJournal,
        now: @escaping @Sendable () -> Date,
        recordBinding: @escaping @Sendable (V2DeviceRecord) async -> Bool
    ) async throws -> IrxClientSession {
        let context = try await provider()
        guard await context.isCurrent() else { throw DeviceLinkError.notConnected }
        let cache = await context.control.snapshot().cache
        let intent = IrxMacPeerAuthorization(deviceID: instance.deviceID, tag: instance.tag, endpointID: endpoint)
        let target = try intent.resolve(cache: cache, localIdentity: context.localDevice.descriptor.identity, now: now())
        let relay = target.descriptor.metadata.relayURLs.first { cache.directory?.relayURLs.contains($0) == true }
        guard let relay else { throw DeviceLinkError.notConnected }
        var credentials = Self.relayCredentials(cache, at: now())
        if credentials.isEmpty {
            _ = try await context.control.refreshRelayCredentials()
            credentials = Self.relayCredentials(await context.control.snapshot().cache, at: now())
        }
        guard await context.isCurrent(), !credentials.isEmpty else { throw DeviceLinkError.notConnected }
        let address = try context.supervisor.dialAddress(peerEndpointIDHex: endpoint, relayURL: relay, directAddresses: [])
        let connection = try await context.supervisor.dial(address: address, credentials: credentials)
        do {
            guard await context.isCurrent() else { throw DeviceLinkError.notConnected }
            let (admit, control) = try await IrxAdmission().performClient(connection: connection, journal: journal)
            let latest = try intent.resolve(cache: await context.control.snapshot().cache,
                localIdentity: context.localDevice.descriptor.identity, now: now())
            guard latest.deviceRecordID == target.deviceRecordID,
                  latest.descriptor.identityGeneration == target.descriptor.identityGeneration,
                  await context.isCurrent(), await recordBinding(target) else { throw DeviceLinkError.identityMismatch }
            await connection.raiseRemoteStreamCredit(bi: 0, uni: 4)
            if context.allowsDirectPaths { await connection.authorizeDirectPaths() }
            return IrxClientSession(connection: connection, admit: admit, control: control, establishedAt: now())
        } catch {
            await connection.close(code: .userRequested, origin: .local)
            throw error
        }
    }
}
