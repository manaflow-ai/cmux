import CMUXMobileCore
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation

extension MobileHostPeerRuntime {
    // MARK: - Inbound connections

    /// One handler per activation. Runs the single-phase admission handshake
    /// and, on success, registers the session with the composition root. The
    /// handler returns promptly so the listener's unauthenticated slot frees.
    nonisolated static func makeConnectionHandler(
        runtime: MobileHostPeerRuntime,
        acceptor: PeerHostSessionAcceptor,
        admission: PeerAdmissionController,
        revision: UInt64,
        generation: PeerTransportGeneration
    ) -> PeerInboundListener.ConnectionHandler {
        { [weak runtime] connection in
            guard let session = await acceptor.accept(
                connection: connection,
                admission: admission
            ) else {
                MobileHostPeerRuntime.hostDiagnosticLog.record(DiagnosticEvent(
                    .admissionFailed,
                    a: DiagnosticTransportKind.iroh.rawValue
                ))
                return
            }
            guard let runtime else {
                await session.close(reason: "runtime-gone")
                return
            }
            await runtime.registerSession(
                session,
                revision: revision,
                generation: generation
            )
        }
    }

    /// Composes one admitted session: control RPC over the admitted control
    /// transport, application lanes through the lane router, an independent
    /// server-event lane, and the ≤30s broker revalidation monitor. The old
    /// connection supervisor's race is expressed directly as a task group.
    func registerSession(
        _ session: PeerHostSession,
        revision: UInt64,
        generation: PeerTransportGeneration
    ) {
        guard let active, active.revision == revision,
              revision == lifecycleRevision else {
            Task { await session.close(reason: "superseded") }
            return
        }
        let id = UUID()
        let diagnosticSessionID = makeDiagnosticSessionID()
        let diagnosticLog = diagnosticLog
        diagnosticLog.record(DiagnosticEvent(
            .admissionSucceeded,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        CmuxEventBus.shared.publish(
            name: "mobile.iroh.admission.succeeded",
            category: "mobile",
            source: "mobile.iroh.host"
        )
        diagnosticLog.record(DiagnosticEvent(
            .transportSessionLifecycle,
            a: DiagnosticSessionLifecycleKind.established.rawValue,
            b: Int(CmxTransportSessionPurpose.foregroundControl.rawValue),
            c: diagnosticSessionID
        ))

        let admissionInfo = MobileHostPeerAdmission(
            peerEndpointID: session.peerEndpointID,
            grantID: session.grant.grantID,
            initiatorDeviceID: session.grant.initiatorDeviceID,
            acceptorDeviceID: session.grant.acceptorDeviceID
        )
        let eventWriter = MobileHostPeerServerEventWriter(session: session)
        let artifactTransfers = MobileHostPeerArtifactTransferRegistry()
        let laneRouter = MobileHostPeerLaneRouter(
            session: session,
            peer: admissionInfo,
            artifactHandler: MobileHostPeerArtifactLaneHandler(
                registry: artifactTransfers
            )
        )
        let manager = endpointManager
        let isCurrent: @Sendable () async -> Bool = {
            manager.isCurrent(generation)
        }

        let task = Task { [weak self] in
            await session.startRevalidationMonitor()
            let controlExit = await withTaskGroup(
                of: Void.self,
                returning: MobileHostConnectionExit.self
            ) { group in
                group.addTask {
                    await laneRouter.run(isCurrent: isCurrent)
                }
                let exit = await MobileHostService.acceptTransport(
                    session.controlTransport,
                    authorization: .peerAdmission(admissionInfo),
                    artifactTransfers: artifactTransfers,
                    independentEventWriter: eventWriter,
                    isCurrent: isCurrent
                )
                group.cancelAll()
                await session.close(reason: "control-finished")
                await laneRouter.stop()
                return exit
            }
            let sessionExit = await session.awaitExit()
            let attributed = Self.attributedExit(
                controlExit: controlExit,
                sessionExit: sessionExit
            )
            diagnosticLog.record(DiagnosticEvent(
                .transportSessionLifecycle,
                a: attributed.lifecycle.rawValue,
                b: Int(CmxTransportSessionPurpose.foregroundControl.rawValue),
                c: diagnosticSessionID
            ))
            diagnosticLog.record(DiagnosticEvent(
                .sessionClosed,
                a: DiagnosticTransportKind.iroh.rawValue,
                b: attributed.failure == .none ? nil : attributed.failure.rawValue,
                c: diagnosticSessionID
            ))
            await self?.sessionDidFinish(id, revision: revision)
        }
        active.sessionTasks[id] = task
    }

    func sessionDidFinish(_ id: UUID, revision: UInt64) {
        guard let active, active.revision == revision else { return }
        active.sessionTasks[id] = nil
    }

    /// Prefers the control protocol's own exit attribution; the QUIC-level
    /// exit overrides it only for a broker-confirmed revocation, which the
    /// control layer cannot observe.
    nonisolated static func attributedExit(
        controlExit: MobileHostConnectionExit,
        sessionExit: PeerSessionExit
    ) -> MobileHostConnectionExit {
        if case .revoked = sessionExit.reason {
            return MobileHostConnectionExit(
                lifecycle: .explicitlyInvalidated,
                failure: .admissionRevalidationFailed
            )
        }
        return controlExit
    }
}
