import CmuxNextDaemon

extension CloudService {
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
