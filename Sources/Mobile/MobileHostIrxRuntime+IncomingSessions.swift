import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

extension MobileHostIrxRuntime {
    func superviseConnection(
        _ irx: IrxConnection,
        judge: IrxListJudge,
        registry: IrxServerSessionRegistry,
        token: UUID
    ) async {
        let journal = Self.journal
        guard MobileRemoteControlPolicy.allowsIncomingAccess() else {
            await irx.close(code: .hostShutdown, origin: .local)
            return
        }
        guard
            let (peer, control, sessionID) = await IrxAdmission.performServer(
                connection: irx,
                judgment: judge.judgment(),
                journal: journal
            )
        else { return }
        let registered = await registry.admit(
            deviceID: peer.deviceID,
            sessionID: sessionID,
            connection: irx,
            stillAuthorized: { endpointIDHex in
                guard MobileRemoteControlPolicy.allowsIncomingAccess() else { return false }
                do {
                    _ = try judge.judgment()(nil, endpointIDHex)
                    return true
                } catch {
                    return false
                }
            }
        )
        guard registered else { return }
        // Automatic path mode: authorize NAT traversal so the admitted session
        // can upgrade to a direct/LAN path make-before-break.
        if !Self.forceRelayOnly {
            await irx.authorizeDirectPaths()
        }

        let admittedPeer: CmxIrohAdmittedPeer
        do {
            admittedPeer = CmxIrohAdmittedPeer(
                accountDeviceBindingID: peer.bindingID,
                deviceID: peer.deviceID,
                endpointID: try CmxIrohPeerIdentity(endpointID: peer.endpointIDHex),
                identityGeneration: peer.identityGeneration
            )
        } catch {
            await irx.close(code: .identityMismatch, origin: .local)
            return
        }

        let artifactRegistry = MobileHostIrohArtifactTransferRegistry()
        let eventWriter = MobileHostIrxEventWriter(connection: irx, journal: journal)
        let laneLoop = Task {
            await Self.runLaneLoop(
                irx, admittedPeer: admittedPeer, artifactRegistry: artifactRegistry,
                journal: journal)
        }
        let controlTransport = IrxControlByteTransport(
            connection: irx, control: control, closeCode: .hostShutdown)
        let exit = await MobileHostService.acceptTransport(
            controlTransport,
            authorization: .irohAdmission(admittedPeer),
            artifactTransfers: artifactRegistry,
            independentEventWriter: eventWriter,
            // The bounded Iroh peer pool stays alive via transport keepalives.
            // Control-idle timeout is for unowned legacy TCP connections and
            // must not tear down a healthy multi-lane QUIC session.
            idleTimeoutNanoseconds: 0,
            isCurrent: { [weak self] in
                let runtime = self
                return await MainActor.run { runtime?.generationToken == token }
            }
        )
        journal.record(
            "host-runtime", "connection-exit",
            [
                "session": sessionID,
                "lifecycle": String(describing: exit.lifecycle),
                "failure": String(describing: exit.failure),
            ]
        )
        laneLoop.cancel()
        await eventWriter.close()
        await irx.close(code: .hostShutdown, origin: .local)
        await registry.remove(deviceID: peer.deviceID, sessionID: sessionID)
    }

}
