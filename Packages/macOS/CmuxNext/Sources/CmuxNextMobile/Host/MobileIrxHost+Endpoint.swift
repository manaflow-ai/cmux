import CmuxIrxTransport
import Foundation

/// Endpoint readiness, the accept loop, and permission enforcement.
extension MobileIrxHost {
    /// Longest wait between endpoint activation attempts.
    static let maximumRetryDelay: Duration = .seconds(300)

    /// Binds (or re-binds) the endpoint once a usable relay credential exists,
    /// then starts accepting. Coalesces concurrent requests into one task.
    func requestEndpointReady() {
        guard endpointTask == nil else { endpointRefreshPending = true; return }
        guard let supervisor, let cache = cachedState, !cache.authorityRevoked,
              Self.credentials(cache).contains(where: { $0.isUsable(at: Date()) }) else {
            journal.record("next-host", "endpoint-ready-skipped", [:])
            return
        }
        endpointTask = Task { [weak self] in
            var failures = 0
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
                    await self.recordEndpointFailure(error)
                    let delay = min(Duration.seconds(5) * (1 << min(failures, 6)), Self.maximumRetryDelay)
                    failures += 1
                    // Intentional bounded backoff on the injected clock, cancelled with the task.
                    do { try await self.clock.sleep(for: delay) } catch { return }
                }
            }
        }
    }

    private func recordEndpointFailure(_ error: any Error) {
        journal.record("next-host", "endpoint-failed", ["error": String(describing: type(of: error))])
        guard supervisor != nil else { return }
        phase = .failed("relay endpoint unavailable")
    }

    private func endpointBecameReady(_ supervisor: IrxEndpointSupervisor) async {
        guard self.supervisor === supervisor else { return }
        endpointTask = nil
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
            while !Task.isCancelled {
                guard let inbound = await supervisor.acceptNextInbound() else {
                    await self?.acceptLoopEnded()
                    return
                }
                switch inbound {
                case .irx(let connection):
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

    private func acceptLoopEnded() {
        acceptTask = nil
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

    /// Re-enforces at the next permission expiry.
    func scheduleExpiry() {
        expiryTask?.cancel()
        guard let deadline = admission?.nextExpiration else { return }
        expiryTask = Task { [weak self] in
            guard let self else { return }
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            await self.enforcePermissions()
            await self.scheduleExpiry()
        }
    }
}
