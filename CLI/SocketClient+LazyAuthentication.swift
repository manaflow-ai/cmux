import Foundation

extension SocketClient {
    func retryAfterAuthenticationChallenge(
        response: String,
        command: String,
        operationDeadline: Date
    ) throws -> String? {
        guard !authenticationInProgress,
              !authenticationPasswordResolutionAttempted,
              SocketAuthenticationChallenge.isRequired(response),
              let authenticationPasswordProvider else {
            return nil
        }
        authenticationPasswordResolutionAttempted = true
        guard let password = authenticationPasswordProvider() else { return nil }
        authenticationPassword = password
        socketAuthenticated = false
        let remaining = operationDeadline.timeIntervalSinceNow
        guard remaining > 0 else { throw CLIError(message: "Command timed out") }
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

    func recordCredentialFreeResponseIfNeeded(_ response: String) {
        if authenticationPasswordProvider != nil,
           !SocketAuthenticationChallenge.isRequired(response) {
            authenticationModeEstablished = true
        }
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
