import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

/// Serves the legacy wire dialect (`cmux/mobile/1`) for old phone builds over
/// a connection accepted by the irx endpoint. One endpoint, one identity, two
/// protocols: old phones keep working while irx is primary, and they get
/// irx's endpoint/credential management underneath (the flaky legacy runtime
/// machinery stays retired). Admission, lanes, and RPC reuse the proven
/// legacy session classes unchanged.
enum MobileHostIrxLegacyDialectServer {
    static let listenerDefaultsKey = "cmux.irx.legacy-listener"

    /// The legacy listener's own brake: disabling it never touches irx.
    /// Defaults ON (old phones keep working out of the box).
    nonisolated static var listenerEnabled: Bool {
        if UserDefaults.standard.object(forKey: listenerDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: listenerDefaultsKey)
    }

    /// The legacy wire protocol tag (`IROH_ALPN` on the backend, baked into
    /// every shipped BETA build).
    nonisolated static var legacyALPN: Data {
        Data("cmux/mobile/1".utf8)
    }

    /// Runs one legacy connection end to end: admission barrier, control RPC
    /// via MobileHostService, application lanes via the legacy router.
    static func serve(
        adopted connection: any CmxIrohConnection,
        acceptor: CmxIrohGrantPeer,
        trust: IrxTrustSnapshot,
        brokerClient: CmxIrohTrustBrokerClient,
        listCurrent: IrxDeviceListCurrent,
        sessions: MobileHostIrxLegacyDialectSessions,
        isCurrent: @escaping @Sendable () async -> Bool,
        journal: IrxJournal
    ) async {
        let remoteEndpoint = (await connection.remoteIdentity()).endpointID
        guard isStillAuthorized(
            remoteEndpoint: remoteEndpoint,
            list: listCurrent.current,
            listeningEnabled: true,
            now: .now
        ) else {
            journal.record("legacy-dialect", "list-denied", ["remote": String(remoteEndpoint.prefix(12))])
            await connection.close(errorCode: 2, reason: "legacy_not_authorized")
            return
        }
        let onlineRegistry = CmxIrohOnlineAdmissionRegistry(
            broker: brokerClient,
            keys: trust.verificationKeys,
            acceptor: acceptor,
            managedRelayURLs: Set(trust.relayFleet)
        )
        let admissionController = CmxIrohAdmissionController(
            acceptor: acceptor,
            pairingEnabled: true,
            offlineSessions: CmxIrohOfflinePairingSessions(pairingEnabled: true),
            onlineRegistry: onlineRegistry
        )
        let session: CmxIrohServerSession
        do {
            session = try CmxIrohServerSession(
                connection: connection,
                authorizer: admissionController,
                protocolConfiguration: .cmuxMobileV1
            )
        } catch {
            journal.record(
                "legacy-dialect", "session-init-failed",
                ["error": String(describing: error)]
            )
            await connection.close(errorCode: 1, reason: "legacy_session_init")
            return
        }
        let peer: CmxIrohAdmittedPeer
        do {
            peer = try await session.admit()
        } catch {
            journal.record(
                "legacy-dialect", "admission-failed",
                ["error": String(describing: error)]
            )
            return
        }
        journal.record(
            "legacy-dialect", "admitted",
            ["device": peer.deviceID, "binding": peer.bindingID]
        )
        // The v2 runtime owns diagnostics. Keep the legacy dialect observable
        // without reaching into the retired MobileHostIrohRuntime singleton.
        journal.record("legacy-dialect", "admission-succeeded", ["device": peer.deviceID])
        if let onlineLease = try? await session.admittedOnlineLease() {
            await onlineRegistry.monitor(onlineLease, connection: connection) { reason in
                journal.record(
                    "legacy-dialect", "lease-closed",
                    ["reason": String(describing: reason)]
                )
                await session.close()
            }
        }

        let stillAuthorized: @Sendable () -> Bool = {
            isStillAuthorized(
                remoteEndpoint: remoteEndpoint,
                list: listCurrent.current,
                listeningEnabled: MobileHostService.isListeningEnabled,
                now: .now
            )
        }
        let admitted = CmxIrohAdmittedServerSession(
            peer: peer,
            session: session,
            promoteUsableSession: { true }
        )
        // Register before serving so a revocation that lands during setup is
        // enforced, and so every later directory update can cut this session
        // (terminal and artifact lanes do not pass through the RPC gate).
        let sessionID = UUID()
        guard await sessions.register(
            id: sessionID,
            stillAuthorized: stillAuthorized,
            close: { await admitted.close() }
        ) else {
            journal.record("legacy-dialect", "admit-revoked", ["device": peer.deviceID])
            await admitted.close()
            return
        }
        let eventWriter = MobileHostIrohServerEventWriter(session: admitted)
        let artifactTransfers = MobileHostIrohArtifactTransferRegistry()
        let laneRouter = MobileHostIrohApplicationLaneRouter(
            session: admitted,
            artifactHandler: MobileHostIrohArtifactLaneHandler(
                registry: artifactTransfers
            ),
            simulatorStreamHandler: MobileHostIrohSimulatorStreamLaneHandler()
        )
        let supervisor = CmxIrohAdmittedConnectionSupervisor(
            runControl: {
                await MobileHostService.acceptTransport(
                    admitted.controlTransport,
                    authorization: .irohAdmission(admitted.peer),
                    hostDeviceID: acceptor.deviceID,
                    artifactTransfers: artifactTransfers,
                    independentEventWriter: eventWriter,
                    firstFrameTimeoutNanoseconds: 0,
                    promoteUsableSession: { await admitted.markUsable() },
                    irohAdmissionIsAuthorized: { stillAuthorized() },
                    remoteControlDisabledByPolicy: { !stillAuthorized() },
                    isCurrent: isCurrent
                )
            },
            runApplicationLanes: {
                await laneRouter.run(isCurrent: isCurrent)
            },
            closeConnection: {
                await admitted.close()
            },
            stopApplicationLanes: {
                await laneRouter.stop()
            }
        )
        let observedExit = await supervisor.run()
        await sessions.remove(id: sessionID)
        let exit = await admitted.connectionExit(resolving: observedExit)
        journal.record(
            "legacy-dialect", "connection-exit",
            [
                "device": peer.deviceID,
                "lifecycle": String(describing: exit.lifecycle),
                "failure": String(describing: exit.failure),
            ]
        )
    }

    /// Live authorization for an admitted legacy peer, re-evaluated before
    /// every RPC and on every directory update. It is the admission gate at
    /// the top of ``serve(adopted:acceptor:trust:brokerClient:listCurrent:sessions:isCurrent:journal:)``
    /// plus the listening setting: the device list must still be fresh and
    /// the peer's entry must still be present, not revoked, and not upgraded
    /// to v2.
    nonisolated static func isStillAuthorized(
        remoteEndpoint: String,
        list: IrxDeviceListSnapshot?,
        listeningEnabled: Bool,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard listeningEnabled,
              let list,
              list.isFresh(now: now),
              let entry = list.entries[remoteEndpoint] else {
            return false
        }
        return !entry.revoked
            && entry.capabilities?.contains(LegacyCompatibilityService.v2Capability) != true
    }
}

/// Live legacy-dialect sessions, so directory enforcement can cut a revoked
/// legacy peer immediately instead of waiting for its next RPC. Legacy
/// connections are not irx connections, so they cannot join
/// `IrxServerSessionRegistry`.
actor MobileHostIrxLegacyDialectSessions {
    private struct Entry {
        let stillAuthorized: @Sendable () -> Bool
        let close: @Sendable () async -> Void
    }

    private var entries: [UUID: Entry] = [:]

    var activeSessionCount: Int { entries.count }

    /// Registers an admitted session. Returns false, without registering,
    /// when the session is already unauthorized.
    func register(
        id: UUID,
        stillAuthorized: @escaping @Sendable () -> Bool,
        close: @escaping @Sendable () async -> Void
    ) -> Bool {
        guard stillAuthorized() else { return false }
        entries[id] = Entry(stillAuthorized: stillAuthorized, close: close)
        return true
    }

    func remove(id: UUID) {
        entries[id] = nil
    }

    /// Closes every session whose live authorization no longer holds.
    func closeUnauthorized() async {
        let revoked = entries.filter { !$0.value.stillAuthorized() }
        for (id, entry) in revoked {
            entries[id] = nil
            await entry.close()
        }
    }

    /// Closes every session, for runtime teardown.
    func closeAll() async {
        let all = entries
        entries.removeAll()
        for entry in all.values {
            await entry.close()
        }
    }
}
