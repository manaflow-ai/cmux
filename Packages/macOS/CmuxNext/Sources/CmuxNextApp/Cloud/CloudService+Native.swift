import CmuxNextCloud
import CmuxNextDaemon

extension CloudService {
    /// The verified provider retires the daemon's outer cache before any Native binding replacement.
    func invalidateNativeLink() async throws {
        guard let provider = credentialProvider else { throw CloudTeamScope.Failure.unavailable }
        guard let connection = machines.local.connection else { provider.stop(); throw DaemonError.notConnected }
        // task-owner: transaction; joining it survives cancellation of the provider call being retired.
        let transaction = Task { await provider.scopeChanged { try await connection.request($0) } }
        guard await transaction.value else { throw CloudTeamScope.Failure.unavailable }
    }

    func ensureNativeLinkReport() async -> JSONValue {
        guard mayCallCloud, !policyDisabled, auth.isSignedIn, !isSigningOut, credentialProvider?.isReady == true, let nativeLink else {
            return .object(["error": .string("Cloud is not available")])
        }
        do {
            let scope = try await teamScope.snapshot()
            let socket = try await nativeLink.ensure(scope)
            try await scope.recheck(); try cloudTeam.check(scope)
            return .object(["status": .string("running"), "socket": .string(socket)])
        } catch {
            logger.error("Native link ensure refused: \(String(describing: error), privacy: .public)")
            return .object(["error": .string(String(describing: error))])
        }
    }
}
