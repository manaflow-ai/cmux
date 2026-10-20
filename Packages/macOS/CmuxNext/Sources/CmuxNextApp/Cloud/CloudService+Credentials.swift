import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon

extension CloudService {
    /// Serves the `credential` family on the local daemon: answers its
    /// calls on the connection that sent them, and registers again after
    /// every handshake of the verified app connection (a reconnected
    /// connection is a new provider; its calls in flight ended with it).
    /// Only the app server path uses it: with the legacy link (the release
    /// and default Debug path) the relay never registers.
    func startCredentialProvider() {
        guard configuration.linkSource == .appServer, let provider = credentialProvider, credentialEvents == nil else { return }
        let local = machines.local
        credentialEvents = local.store.sideEvents.subscribe { [weak local] event in
            guard let connection = local?.connection else { return }
            provider.handle(event) { result in _ = try await connection.request(result) }
        }
        // task-owner: observers; cancelled in stop()
        observers.append(Task {
            for await state in ObservationStream({ local.store.connectionState }) {
                guard case .connected = state, let connection = local.connection else { provider.stop(); continue }
                let allowed = await connection.userOriginAllowed
                _ = await provider.register(userOriginAllowed: allowed,
                    send: { try await connection.request($0) }, invalidate: { try await connection.request($0) })
            }
        })
        let selection = cloudTeam
        let changes = ObservationStream.current { try? selection.current() }.later
        // task-owner: observers; closes idle resources even when no Cloud operation follows the change.
        observers.append(Task { [weak self] in
            for await selection in changes {
                guard let self else { return }
                if let authoritySession = self.authoritySession,
                   let identity = self.auth.coordinator.authenticatedSessionIdentity {
                    authoritySession.selectionChanged(identity, selection: selection)
                    continue
                }
                self.dropAllMachines()
                if let nativeLink = self.nativeLink { await nativeLink.retire(); continue }
                guard let connection = local.connection else { provider.stop(); continue }
                await provider.scopeChanged { try await connection.request($0) }
            }
        })
    }

    /// Only a live sign-in can reopen the provider; a reconnect cannot end the sign-out barrier.
    func beginCredentialSession(identity: CloudSessionLifecycle.Identity) async {
        guard configuration.linkSource == .appServer, let provider = credentialProvider else { return }
        await provider.waitForSessionDrain()
        guard isCloudSessionCurrent(identity), !Task.isCancelled, (try? observedAuthority.snapshot()) != nil else { return }
        provider.beginSession()
        guard let connection = machines.local.connection else { return }
        let allowed = await connection.userOriginAllowed
        guard isCloudSessionCurrent(identity), (try? observedAuthority.snapshot()) != nil else { return }
        _ = await provider.register(userOriginAllowed: allowed,
            send: { try await connection.request($0) }, invalidate: { try await connection.request($0) })
    }

    /// Drains current and previously cancelled credential work before unbinding or rotating keys.
    func endCredentialSession() async {
        guard configuration.linkSource == .appServer, let provider = credentialProvider else { return }
        if let connection = machines.local.connection {
            await provider.endSession { try await connection.request($0) }
        } else {
            await provider.endSession(send: nil)
        }
    }
}
