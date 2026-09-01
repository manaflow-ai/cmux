import Foundation
import CmuxCLISocketAuth

extension SocketClient {
    /// Replays a request once after the local control socket challenges it.
    func retryAfterAuthenticationChallenge(
        response: String,
        command: String,
        operationDeadline: Date
    ) throws -> String? {
        guard !authenticationInProgress,
              !authenticationPasswordResolutionAttempted,
              SocketAuthenticationChallenge.isRequired(response),
              authenticationPasswordProvider != nil else {
            return nil
        }
        guard let password = resolveDeferredAuthenticationPassword(deadline: operationDeadline) else {
            return nil
        }
        authenticationPassword = password
        socketAuthenticated = false
        let remaining = operationDeadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw CLIError(message: String(
                localized: "cli.socket.error.commandTimedOut",
                defaultValue: "Command timed out"
            ))
        }
        let retriedResponse = try send(
            command: command,
            responseTimeout: remaining,
            deadline: operationDeadline,
            allowAuthenticationRetry: false
        )
        if !SocketAuthenticationChallenge.isRequired(retriedResponse) {
            authenticationModeEstablished = true
        }
        return retriedResponse
    }

    /// Records that this socket accepted a request without credentials.
    func recordCredentialFreeResponseIfNeeded(_ response: String) {
        if authenticationPasswordProvider != nil,
           !SocketAuthenticationChallenge.isRequired(response) {
            authenticationModeEstablished = true
        }
    }

    /// Resolves the deferred provider within the request's remaining deadline.
    func resolveDeferredAuthenticationPassword(deadline: Date?) -> String? {
        if let deadline, deadline.timeIntervalSinceNow <= 0 {
            return nil
        }
        authenticationPasswordResolutionAttempted = true
        let password = authenticationPasswordProvider?(deadline)
        if let deadline, deadline.timeIntervalSinceNow <= 0 {
            return nil
        }
        return password
    }

    /// Probes once before a write-only request when authentication is deferred.
    func establishAuthenticationForOneWayIfNeeded(responseTimeout: TimeInterval) throws {
        guard authenticationPassword == nil,
              authenticationPasswordProvider != nil,
              !authenticationPasswordResolutionAttempted,
              !authenticationModeEstablished else { return }
        _ = try send(command: "ping", responseTimeout: responseTimeout)
    }
}
