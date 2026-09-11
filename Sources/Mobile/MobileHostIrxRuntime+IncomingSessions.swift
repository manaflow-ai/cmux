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
        // One authorization rule for the whole life of the session: the lease
        // is fresh, the peer is listed and not revoked, and the admitted tuple
        // still matches the directory. Admission, the request gate, the lease
        // deadline, and directory enforcement all consult it.
        let deviceListBox = self.deviceListBox
        let remainsAuthorized: @Sendable () -> Bool = {
            Self.admittedPeerRemainsAuthorized(snapshot: deviceListBox?.current, peer: peer, now: .now)
        }
        let registered = await registry.admit(
            deviceID: peer.deviceID,
            sessionID: sessionID,
            connection: irx,
            stillAuthorized: { endpointIDHex in
                guard MobileRemoteControlPolicy.allowsIncomingAccess() else { return false }
                do {
                    _ = try judge.judgment()(nil, endpointIDHex)
                } catch {
                    return false
                }
                return remainsAuthorized()
            }
        )
        guard registered else { return }
        // The device-list lease is the host's offline authorization boundary.
        // Admission checks it once, but a live QUIC session can outlast the
        // control-plane connection. Re-check before every RPC and close at the
        // current lease deadline so an outage cannot turn a temporary grant
        // into indefinite terminal control.
        let leaseExpiryTask = Task { [peer] in
            while !Task.isCancelled {
                guard let snapshot = deviceListBox?.current,
                      Self.admittedPeerRemainsAuthorized(snapshot: snapshot, peer: peer, now: .now) else {
                    await irx.close(code: .revoked, origin: .local)
                    return
                }
                let elapsed = snapshot.receivedAtMonotonic.duration(to: .now)
                let remaining = .seconds(snapshot.ttlSeconds) - elapsed
                do {
                    try await Task.sleep(for: remaining)
                } catch {
                    return
                }
            }
        }
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
            // Undo the registration this session already holds: the expiry
            // task would otherwise retain the connection until the lease
            // deadline and later close a finished session as revoked.
            leaseExpiryTask.cancel()
            await irx.close(code: .identityMismatch, origin: .local)
            await registry.remove(deviceID: peer.deviceID, sessionID: sessionID)
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
            irohAdmissionIsAuthorized: { remainsAuthorized() },
            isCurrent: { [weak self] in
                let runtime = self
                return await MainActor.run { runtime?.generationToken == token }
            }
        )
        leaseExpiryTask.cancel()
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

    /// The offline authorization the host re-checks for a LIVE session: the
    /// lease is fresh, the peer is still listed and not revoked, and every
    /// tuple field the directory carries still matches what admission proved.
    /// Identity drift (a rebound device ID, tag, binding, or generation)
    /// disqualifies the session exactly like a revocation does.
    nonisolated static func admittedPeerRemainsAuthorized(
        snapshot: IrxDeviceListSnapshot?,
        peer: IrxAdmittedPeerInfo,
        now: ContinuousClock.Instant
    ) -> Bool {
        guard let snapshot, snapshot.isFresh(now: now),
              let entry = snapshot.entries[peer.endpointIDHex],
              !entry.revoked else { return false }
        if let deviceID = entry.deviceID, deviceID != peer.deviceID { return false }
        if let tag = entry.tag, tag != peer.tag { return false }
        if let bindingID = entry.bindingID, bindingID != peer.bindingID { return false }
        if let generation = entry.identityGeneration, generation != peer.identityGeneration { return false }
        return true
    }
}
