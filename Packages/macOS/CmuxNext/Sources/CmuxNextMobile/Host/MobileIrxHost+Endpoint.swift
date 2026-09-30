import CmuxIrxTransport
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// Endpoint readiness, the accept loop, and permission enforcement.
extension MobileIrxHost {
    /// Endpoint activation: 5 s growing to 300 s, 8 timed attempts; after
    /// that the next relay-state change (`apply`) retries. No fixed period.
    static let endpointRetry = RetryPolicy(initial: .seconds(5), maximum: .seconds(300), timedRetries: 8)
    /// An accept loop that ended without accepting anything (the endpoint
    /// closed at once, or every handshake failed): 250 ms growing to 60 s,
    /// 10 timed cycles, then the next relay-state change.
    static let acceptRetry = RetryPolicy(initial: .milliseconds(250), maximum: .seconds(60), timedRetries: 10)

    /// Binds (or re-binds) the endpoint once a usable relay credential exists,
    /// then starts accepting. Coalesces concurrent requests into one task.
    func requestEndpointReady() {
        guard endpointTask == nil else {
            endpointRefreshPending = true
            endpointWake.fire()
            return
        }
        guard let supervisor, let cache = cachedState, !cache.authorityRevoked,
              Self.credentials(cache).contains(where: { $0.isUsable(at: Date()) }) else {
            journal.record("next-host", "endpoint-ready-skipped", [:])
            return
        }
        let wake = endpointWake
        let clock = clock
        endpointTask = Task { [weak self] in
            // wakeup-allow: each failed activation waits in RetryWake (capped backoff, then relay-state events only)
            while !Task.isCancelled {
                guard let self, let cache = await self.cachedState else { return }
                do {
                    _ = try await supervisor.readyEndpoint(credentials: Self.credentials(cache))
                    // Teardown cancels this task; never revive the phase or
                    // the accept loop after it.
                    guard !Task.isCancelled else { return }
                    await self.endpointBecameReady(supervisor)
                    return
                } catch {
                    guard let delay = await self.recordEndpointFailure(error) else { return }
                    wake.rebaseline()
                    guard await wake.awaitWake(delay: delay, clock: clock) != .cancelled else { return }
                }
            }
        }
    }

    /// Notes a failed activation; returns the spacing before the next one,
    /// or nil when the budget is spent (the next relay-state change retries).
    private func recordEndpointFailure(_ error: any Error) -> Duration? {
        journal.record("next-host", "endpoint-failed", ["error": String(describing: type(of: error))])
        if supervisor != nil { phase = .failed("relay endpoint unavailable") }
        let delay = endpointPacer.failed()
        if delay == nil {
            endpointTask = nil
            journal.record("next-host", "endpoint-retries-spent", [:])
        }
        return delay
    }

    private func endpointBecameReady(_ supervisor: IrxEndpointSupervisor) async {
        guard self.supervisor === supervisor else { return }
        endpointTask = nil
        endpointPacer.reset()
        let relay = await supervisor.homeRelayURL()
        phase = .listening(relayURL: relay)
        journal.record("next-host", "endpoint-ready", ["relay": relay ?? "-"])
        startAcceptLoop()
        await publishHomeRelay(relay)
        if endpointRefreshPending {
            endpointRefreshPending = false
            requestEndpointReady()
        }
    }

    /// Peers address the Mac through its home relay; direct paths stay local.
    private func publishHomeRelay(_ relay: String?) async {
        guard let relay, let service = controlService,
              let metadata = cachedState?.device?.descriptor.metadata, metadata.relayURLs != [relay] else { return }
        let next = V2DeviceMetadata(appVersion: metadata.appVersion, capabilities: metadata.capabilities,
                                    displayName: metadata.displayName, pairingEnabled: metadata.pairingEnabled,
                                    platform: metadata.platform, relayURLs: [relay])
        do {
            try await service.updateMetadata(next)
        } catch {
            journal.record("next-host", "relay-publish-failed", ["error": String(describing: type(of: error))])
        }
    }

    private func startAcceptLoop() {
        guard acceptTask == nil, let supervisor, let admission, let registry else { return }
        let judgment = admission.judgment()
        acceptTask = Task { [weak self] in
            var accepted = false
            // wakeup-allow: awaits the next inbound connection; nil ends the loop (restart is paced by acceptRetry)
            while !Task.isCancelled {
                guard let inbound = await supervisor.acceptNextInbound() else {
                    await self?.acceptLoopEnded(acceptedAny: accepted)
                    return
                }
                accepted = true
                await self?.acceptedInbound()
                switch inbound {
                case .irx(let connection):
                    // task-owner: one per phone connection; ends when teardown closes the registry's sessions
                    Task { [weak self] in
                        await self?.supervise(connection, judgment: judgment, admission: admission, registry: registry)
                    }
                case .foreign(_, let connection):
                    // cmux-next serves no legacy `cmux/mobile/1` dialect.
                    try? connection.close(errorCode: 1, reason: Data("unsupported_alpn".utf8))
                }
            }
        }
    }

    private func acceptedInbound() {
        acceptPacer.reset()
    }

    /// The endpoint closed or a handshake failed. Before, the endpoint was
    /// re-readied at once with the activation backoff reset, so an endpoint
    /// that closed right after binding (or a driver that kept returning nil)
    /// cycled readyEndpoint/accept without pause. Now a cycle that accepted
    /// nothing is spaced by `acceptRetry`, which spans cycles.
    private func acceptLoopEnded(acceptedAny: Bool) {
        acceptTask = nil
        if acceptedAny { acceptPacer.reset() }
        guard let delay = acceptPacer.failed() else {
            journal.record("next-host", "accept-retries-spent", [:])
            phase = .failed("relay endpoint unavailable")
            return
        }
        let timer = DemandTimer(owner: "MobileIrxHost.acceptRestart", clock: clock)
        acceptRestart = timer
        timer.schedule(after: delay) { [weak self] in await self?.restartAfterAcceptEnded(timer) }
    }

    private func restartAfterAcceptEnded(_ timer: DemandTimer) {
        guard acceptRestart === timer else { return }
        acceptRestart = nil
        requestEndpointReady()
    }

    private func supervise(_ irx: IrxConnection, judgment: @escaping IrxGrantJudgment,
                           admission: V2InboundAdmissionAuthority, registry: IrxServerSessionRegistry) async {
        guard let (peer, control, sessionID) = await IrxAdmission().performServer(
            connection: irx, judgment: judgment, journal: journal) else { return }
        let isMac = cachedState?.directory?.inboundPeers?.first {
            $0.device.descriptor.endpointID.caseInsensitiveCompare(peer.endpointIDHex) == .orderedSame
        }?.device.descriptor.metadata.platform == .mac
        guard !isMac, let backend, let macDeviceID else {
            await irx.close(code: .revoked, origin: .local)
            return
        }
        let recheck = admission.recheck(peer)
        guard await registry.admit(deviceID: peer.bindingID, sessionID: sessionID, connection: irx,
                                   stillAuthorized: recheck) else {
            await irx.close(code: .revoked, origin: .local)
            return
        }
        await irx.authorizeDirectPaths()
        journal.record("next-host", "phone-admitted", ["session": sessionID])
        let host = hostInfo(macDeviceID: macDeviceID)
        let onUsable = onUsable
        let server = MobileIrxConnectionServer(
            connection: irx, control: control, deviceID: peer.deviceID,
            makeSession: { emit in MobileCompatSession(backend: backend, host: host, emit: emit, onUsable: onUsable) },
            daemonSocketPath: configuration.daemonSocketPath, journal: journal)
        await server.run()
        await irx.close(code: .hostShutdown, origin: .local)
        await registry.remove(deviceID: peer.bindingID, sessionID: sessionID)
        journal.record("next-host", "phone-closed", ["session": sessionID])
    }

    /// Closes sessions whose v2 permission lapsed or was revoked.
    func enforcePermissions() async {
        guard let admission, let registry else { return }
        await registry.closeAll(code: .revoked, matching: { endpoint in
            admission.authorizedPeer(endpointID: endpoint) == nil
        })
    }

    /// Re-enforces at the next permission expiry (a one-shot deadline,
    /// re-armed for the following expiry only).
    func scheduleExpiry() {
        expiryTimer?.cancel()
        expiryTimer = nil
        guard let deadline = admission?.nextExpiration else { return }
        let timer = DemandTimer(owner: "MobileIrxHost.expiry")
        expiryTimer = timer
        timer.schedule(after: max(.zero, ContinuousClock.now.duration(to: deadline))) { [weak self] in
            guard let self else { return }
            await self.enforcePermissions()
            await self.scheduleExpiry()
        }
    }
}
