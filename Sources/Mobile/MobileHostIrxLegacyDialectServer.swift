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
        isCurrent: @escaping @Sendable () async -> Bool,
        journal: IrxJournal
    ) async {
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
        MobileHostIrohRuntime.hostDiagnosticLog.record(DiagnosticEvent(
            .admissionSucceeded,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        if let onlineLease = try? await session.admittedOnlineLease() {
            await onlineRegistry.monitor(onlineLease, connection: connection) { reason in
                journal.record(
                    "legacy-dialect", "lease-closed",
                    ["reason": String(describing: reason)]
                )
                await session.close()
            }
        }

        let admitted = CmxIrohAdmittedServerSession(
            peer: peer,
            session: session,
            promoteUsableSession: { true }
        )
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
                    artifactTransfers: artifactTransfers,
                    independentEventWriter: eventWriter,
                    promoteUsableSession: { await admitted.markUsable() },
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
}
