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
    private var sessions: [String: Session] = [:]
    private var stopped = false

    init(context: @escaping ContextProvider, journal: IrxJournal) {
        self.context = context
        self.journal = journal
    }

    func transport(
        for request: CmxByteTransportRequest,
        instance: SurfaceDeviceInstanceID
    ) async throws -> any CmxByteTransport {
        let endpoint = try Self.endpoint(for: request, instance: instance)
        let borrowed = try await context()
        guard !stopped, sessions[endpoint] == nil else { throw DeviceLinkError.notConnected }
        let owner = UUID()
        let context = context
        let journal = journal
        let engine = IrxPeerEngine(journal: journal, label: "mac-device") { [weak self] in
            try await Self.dial(
                endpoint: endpoint, instance: instance,
                context: context, journal: journal,
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
            onClose: { [weak self] in await self?.release(endpoint: endpoint, owner: owner) },
            permitsIO: { [weak self] in
                guard await borrowed.isCurrent(),
                      let lease = borrowed.deviceList.current, lease.isFresh(now: .now),
                      let peer = lease.entries[endpoint], !peer.revoked else { return false }
                return await self?.isAuthorized(peer, endpoint: endpoint, owner: owner) == true
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
        let session = try await entry.engine.ensureSession(trigger: "mac-events")
        guard !stopped, sessions[endpoint]?.owner == entry.owner else { throw DeviceLinkError.notConnected }
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    guard let (descriptor, reader) = try await session.connection.acceptUniLane(),
                          descriptor.lane == .events else { throw DeviceLinkError.notConnected }
                    while let chunk = try await reader.readRaw() {
                        try Task.checkCancellation()
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
        let previous = Array(sessions.values)
        sessions.removeAll()
        for session in previous { await session.engine.stop() }
    }

    func enforce(_ snapshot: IrxDeviceListSnapshot) async {
        let revoked = sessions.filter { endpoint, entry in
            guard snapshot.isFresh(now: .now), let peer = snapshot.entries[endpoint] else { return true }
            if peer.revoked { return true }
            switch entry.authorization {
            case .waiting:
                return peer.deviceID != entry.instance.deviceID || peer.tag != entry.instance.tag
            case .verified:
                return !isAuthorized(peer, endpoint: endpoint, owner: entry.owner)
            case .closing:
                return false
            }
        }
        for (endpoint, entry) in revoked { await release(endpoint: endpoint, owner: entry.owner) }
    }

    private func record(binding: CmxIrohBrokerBinding, endpoint: String, owner: UUID) -> Bool {
        guard !stopped, var entry = sessions[endpoint], entry.owner == owner else { return false }
        if case .closing = entry.authorization { return false }
        entry.authorization = .verified(bindingID: binding.bindingID, generation: binding.identityGeneration)
        sessions[endpoint] = entry
        return true
    }

    private func isAuthorized(_ peer: IrxDeviceListEntry, endpoint: String, owner: UUID) -> Bool {
        guard !stopped, let session = sessions[endpoint], session.owner == owner,
              case let .verified(bindingID, generation) = session.authorization else { return false }
        return peer.deviceID == session.instance.deviceID && peer.tag == session.instance.tag
            && peer.bindingID == bindingID
            && (peer.identityGeneration == nil || peer.identityGeneration == generation)
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

    /// Registry/presence routes select a candidate, never its authority or coordinates.
    /// Only a fresh account lease plus the broker's exact binding can authorize the dial.
    private static func dial(
        endpoint: String,
        instance: SurfaceDeviceInstanceID,
        context provider: ContextProvider,
        journal: IrxJournal,
        recordBinding: @escaping @Sendable (CmxIrohBrokerBinding) async -> Bool
    ) async throws -> IrxClientSession {
        let context = try await provider()
        guard await context.isCurrent() else { throw DeviceLinkError.notConnected }
        let discovery = try await context.broker.discover(maximumAge: 30)
        let target: CmxIrohBrokerBinding
        do {
            target = try IrxMacPeerAuthorization(
                deviceID: instance.deviceID, tag: instance.tag, endpointID: endpoint
            ).resolve(bindings: discovery.bindings, lease: context.deviceList.current, localDeviceID: context.localBinding.deviceID)
        } catch let failure as IrxMacPeerAuthorization.Failure {
            switch failure {
            case .unavailable, .staleDirectory: throw DeviceLinkError.notConnected
            case .revoked: throw DeviceLinkError.identityUnproven
            case .identityMismatch: throw DeviceLinkError.identityMismatch
            }
        }
        let now = Date()
        let relay = target.pathHints.first {
            $0.kind == .relayURL && $0.isUsable(at: now)
                && discovery.relayFleet.contains($0.value)
        }?.value
        let direct = context.allowsDirectPaths ? Array(target.pathHints.filter {
            $0.kind == .directAddress && $0.privacyScope == .publicInternet && $0.isUsable(at: now)
        }.prefix(16).map(\.value)) : []
        guard relay != nil || !direct.isEmpty else { throw DeviceLinkError.notConnected }
        let credentials = try await context.relayCredentials.usableCredentials()
        guard await context.isCurrent(), context.deviceList.current?.isFresh(now: .now) == true,
              context.deviceList.current?.entries[endpoint]?.revoked == false else {
            throw DeviceLinkError.notConnected
        }
        let address = try context.supervisor.dialAddress(
            peerEndpointIDHex: endpoint, relayURL: relay, directAddresses: direct
        )
        let connection = try await context.supervisor.dial(address: address, credentials: credentials)
        do {
            guard await context.isCurrent() else { throw DeviceLinkError.notConnected }
            let (admit, control) = try await IrxAdmission.performClient(connection: connection, journal: journal)
            guard await context.isCurrent(), await recordBinding(target) else { throw DeviceLinkError.notConnected }
            await connection.raiseRemoteStreamCredit(bi: 0, uni: 4)
            if context.allowsDirectPaths { await connection.authorizeDirectPaths() }
            return IrxClientSession(connection: connection, admit: admit, control: control, establishedAt: Date())
        } catch {
            await connection.close(code: .userRequested, origin: .local)
            throw error
        }
    }
}
