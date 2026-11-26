import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation

/// Owns outgoing control sessions while borrowing the Mac's single registered endpoint.
actor DeviceIrxClient {
    typealias ContextProvider = @Sendable () async throws -> DeviceIrxClientContext

    /// Returns whether a waiting session has an authoritative local revocation.
    nonisolated static func shouldReleaseWaitingSession(cache: V2CachedState?, releaseAll: Bool = false) -> Bool {
        guard !releaseAll, let cache else { return releaseAll }
        return cache.authorityRevoked || cache.device?.revoked == true
    }

    /// Returns whether an authoritative verified-session failure retires its endpoint slot.
    nonisolated static func shouldReleaseVerifiedSession(after failure: IrxMacPeerAuthorization.Failure) -> Bool {
        switch failure {
        case .staleDirectory:
            return false
        case .unavailable, .revoked, .notDiscoverable, .identityMismatch:
            return true
        }
    }

    private enum Authorization {
        case waiting
        case verified(bindingID: String, generation: Int, source: DeviceDirectorySource)
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
    /// The latest authoritative inputs, so a change to either directory
    /// re-evaluates sessions against both.
    private var latestCache: V2CachedState?
    private var latestAccount: AccountMacDirectorySnapshot?

    /// Only facts used by outgoing discovery invalidate its list. This Mac's
    /// hosting metadata, inbound grants and ticket refreshes do not change it.
    private struct DiscoveryState: Equatable {
        let team: TeamDiscovery?
        let account: AccountDiscovery?

        static func make(cache: V2CachedState?, account: AccountMacDirectorySnapshot?) -> DiscoveryState? {
            let team = TeamDiscovery(cache: cache)
            let account = account.map(AccountDiscovery.init)
            guard team != nil || account != nil else { return nil }
            return DiscoveryState(team: team, account: account)
        }
    }

    /// The account directory facts outgoing discovery reads.
    private struct AccountDiscovery: Equatable {
        let revision: Int
        let macs: [V2DeviceRecord]
        let permissionExpiresAt: Int
        let relayURLs: [String]
        let rules: [String]

        init(_ snapshot: AccountMacDirectorySnapshot) {
            revision = snapshot.directory.revision
            macs = snapshot.directory.macs.sorted { $0.deviceRecordID < $1.deviceRecordID }
            permissionExpiresAt = snapshot.directory.permissionExpiresAt
            relayURLs = snapshot.directory.relayURLs
            rules = snapshot.directory.rules.sorted()
        }
    }

    private struct TeamDiscovery: Equatable {
        let identity: V2Identity
        let devices: [V2DeviceRecord]
        let permissionExpiresAt: Int
        let relayURLs: [String]
        let revoked: Bool
        let rules: [String]

        init?(cache: V2CachedState?) {
            guard let cache, let directory = cache.directory else { return nil }
            identity = cache.identity
            devices = directory.devices.filter {
                $0.descriptor.identity.deviceID.lowercased() != cache.identity.deviceID.lowercased()
                    || $0.descriptor.identity.buildTag != cache.identity.buildTag
            }.sorted { $0.deviceRecordID < $1.deviceRecordID }
            permissionExpiresAt = directory.permissionExpiresAt
            relayURLs = directory.relayURLs
            rules = (directory.rules ?? []).sorted()
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
        let account = await borrowed.accountDirectory()
        return Self.displayBindings(cache: cache, account: account, now: permissionNow())
    }

    /// The stamp of the complete directory that authorizes outgoing control,
    /// or nil before one is loaded.
    func directoryStamp() async -> DeviceDirectoryStamp? {
        guard !stopped, let borrowed = try? await context(), await borrowed.isCurrent(),
              let directory = await borrowed.control.snapshot().cache.directory else { return nil }
        let account = await borrowed.accountDirectory()
        return DeviceDirectoryStamp(revision: directory.revision, issuedAt: directory.issuedAt,
            accountRevision: account?.directory.revision)
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
                recordBinding: { [weak self] binding, source in
                    await self?.record(binding: binding, source: source, endpoint: endpoint, owner: owner) == true
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

    /// Reconciles session authorization against an authoritative control snapshot.
    func enforce(_ cache: V2CachedState?, releaseAll: Bool = false) async {
        latestCache = cache
        await reconcile(releaseAll: releaseAll)
    }

    /// Reconciles session authorization against a new account directory
    /// (nil when none applies, such as an unsupported service or a disabled flag).
    func enforceAccount(_ account: AccountMacDirectorySnapshot?) async {
        // Concurrent installs can deliver an older read after a newer one;
        // for the same requester, a directory only moves forward.
        if let account, let latest = latestAccount, latest.requester == account.requester,
           (account.directory.revision, account.directory.issuedAt)
            < (latest.directory.revision, latest.directory.issuedAt) {
            return
        }
        latestAccount = account
        await reconcile(releaseAll: false)
    }

    private func reconcile(releaseAll: Bool) async {
        let cache = latestCache
        let account = latestAccount
        let revoked = sessions.filter { endpoint, entry in
            if releaseAll { return true }
            guard let cache else { return false }
            switch entry.authorization {
            case .waiting:
                // A control snapshot can be ready before its complete directory
                // has arrived. The dial validates the latest cache at every
                // admission boundary; stopping it here turns that normal race
                // into a user-requested cancellation with no retry signal.
                return Self.shouldReleaseWaitingSession(cache: cache)
            case .verified(_, _, let source):
                do {
                    let peer = try Self.resolveTarget(intent: IrxMacPeerAuthorization(
                        deviceID: entry.instance.deviceID, tag: entry.instance.tag, endpointID: endpoint
                    ), source: source, cache: cache, account: account, localIdentity: cache.identity, now: permissionNow())
                    return !isAuthorized(peer, endpoint: endpoint, owner: entry.owner)
                } catch let failure as IrxMacPeerAuthorization.Failure {
                    return Self.shouldReleaseVerifiedSession(after: failure)
                } catch {
                    return false
                }
            case .closing: return false
            }
        }
        for (endpoint, entry) in revoked { await release(endpoint: endpoint, owner: entry.owner) }
        let discovery = DiscoveryState.make(cache: cache, account: account)
        guard publishedDiscovery != discovery else { return }
        publishedDiscovery = discovery
        for observer in directoryObservers.values { observer.yield(()) }
    }

    private func record(binding: V2DeviceRecord, source: DeviceDirectorySource, endpoint: String, owner: UUID) -> Bool {
        guard !stopped, var entry = sessions[endpoint], entry.owner == owner else { return false }
        if case .closing = entry.authorization { return false }
        entry.authorization = .verified(bindingID: binding.deviceRecordID,
            generation: binding.descriptor.identityGeneration, source: source)
        sessions[endpoint] = entry
        return true
    }

    private func permitsIO(context: DeviceIrxClientContext, endpoint: String, owner: UUID) async -> Bool {
        guard let entry = sessions[endpoint], entry.owner == owner,
              case let .verified(_, _, source) = entry.authorization else { return false }
        let cache = await context.control.snapshot().cache
        let account = await context.accountDirectory()
        guard let peer = try? Self.resolveTarget(intent: IrxMacPeerAuthorization(
            deviceID: entry.instance.deviceID, tag: entry.instance.tag, endpointID: endpoint
        ), source: source, cache: cache, account: account,
            localIdentity: context.localDevice.descriptor.identity, now: permissionNow()) else { return false }
        return isAuthorized(peer, endpoint: endpoint, owner: owner)
    }

    private func isAuthorized(_ target: DeviceResolvedMacTarget, endpoint: String, owner: UUID) -> Bool {
        let peer = target.record
        guard !stopped, let session = sessions[endpoint], session.owner == owner,
              case let .verified(bindingID, generation, source) = session.authorization,
              target.source == source else { return false }
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
        recordBinding: @escaping @Sendable (V2DeviceRecord, DeviceDirectorySource) async -> Bool
    ) async throws -> IrxClientSession {
        let context = try await provider()
        guard await context.isCurrent() else { throw DeviceLinkError.notConnected }
        let cache = await context.control.snapshot().cache
        let intent = IrxMacPeerAuthorization(deviceID: instance.deviceID, tag: instance.tag, endpointID: endpoint)
        let resolved = try Self.resolveTarget(intent: intent, source: nil, cache: cache,
            account: await context.accountDirectory(),
            localIdentity: context.localDevice.descriptor.identity, now: now())
        let target = resolved.record
        let relay = target.descriptor.metadata.relayURLs.first { resolved.relayURLs.contains($0) }
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
            // Post-admit binding recheck. On the direct-path lane it runs
            // inside performClient before NAT traversal is authorized, so a
            // dial that went stale during admission never discloses direct
            // candidates; on the relay-only lane it runs here, exactly once
            // either way (recordBinding has a side effect).
            let recheckBinding: @Sendable () async throws -> Void = {
                try await Self.recheck(intent: intent, resolved: resolved, context: context, now: now,
                    recordBinding: recordBinding)
            }
            let (admit, control) = try await IrxAdmission().performClient(
                connection: connection, journal: journal,
                authorizesDirectPaths: context.allowsDirectPaths,
                preAuthorization: recheckBinding)
            if !context.allowsDirectPaths { try await recheckBinding() }
            await connection.raiseRemoteStreamCredit(bi: 0, uni: 4)
            return IrxClientSession(connection: connection, admit: admit, control: control, establishedAt: now())
        } catch {
            await connection.close(code: .userRequested, origin: .local)
            throw error
        }
    }

    /// The post-admit binding recheck. It resolves only against the directory
    /// that selected the target, so the NAT preAuthorization barrier can never
    /// be satisfied by a different source naming the same endpoint.
    static func recheck(
        intent: IrxMacPeerAuthorization,
        resolved: DeviceResolvedMacTarget,
        context: DeviceIrxClientContext,
        now: @escaping @Sendable () -> Date,
        recordBinding: @escaping @Sendable (V2DeviceRecord, DeviceDirectorySource) async -> Bool
    ) async throws {
        let target = resolved.record
        let latest = try Self.resolveTarget(intent: intent, source: resolved.source,
            cache: await context.control.snapshot().cache,
            account: resolved.source == .account ? await context.accountDirectory() : nil,
            localIdentity: context.localDevice.descriptor.identity, now: now())
        guard latest.source == resolved.source,
              latest.record.deviceRecordID == target.deviceRecordID,
              latest.record.descriptor.identityGeneration == target.descriptor.identityGeneration,
              await context.isCurrent(), await recordBinding(target, resolved.source) else { throw DeviceLinkError.identityMismatch }
    }
}
