import CmuxNextCloud
import CmuxNextDaemon

extension CloudService {
    /// Only a live sign-in can reopen the provider; a reconnect cannot end the sign-out barrier.
    func beginCredentialSession(identity: CloudSessionLifecycle.Identity) async {
        guard configuration.linkSource == .appServer, let provider = credentialProvider else { return }
        await provider.waitForSessionDrain()
        guard isCloudSessionCurrent(identity), !Task.isCancelled else { return }
        provider.beginSession()
        guard let connection = machines.local.connection else { return }
        let allowed = await connection.userOriginAllowed
        guard isCloudSessionCurrent(identity) else { return }
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
