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
        authenticationModeCoordinator?.recordPasswordRequired()
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
            authenticationModeCoordinator?.recordCredentialFree()
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
              authenticationPasswordProvider != nil else { return }
        guard let coordinator = authenticationModeCoordinator else {
            guard !authenticationPasswordResolutionAttempted,
                  !authenticationModeEstablished else { return }
            _ = try send(command: "ping", responseTimeout: responseTimeout)
            return
        }

        let mode = coordinator.current
        switch mode {
        case .credentialFree, .probing, .probeFailed:
            authenticationModeEstablished = mode == .credentialFree
        case .passwordRequired:
            try authenticateOneWayClientIfNeeded(responseTimeout: responseTimeout)
        case .unknown:
            guard coordinator.claimProbe() else { return }
            let probeClient = SocketClient(path: socketPath)
            defer { probeClient.close() }
            probeClient.configureAuthentication(
                password: nil,
                passwordProvider: authenticationPasswordProvider,
                authenticationModeCoordinator: coordinator
            )
            do {
                try probeClient.connectWithoutRetry(responseTimeout: responseTimeout)
                _ = try probeClient.send(command: "ping", responseTimeout: responseTimeout)
            } catch {
                coordinator.recordProbeFailure()
                throw error
            }
            if coordinator.current == .passwordRequired {
                try authenticateOneWayClientIfNeeded(responseTimeout: responseTimeout)
            }
        }
    }

    private func authenticateOneWayClientIfNeeded(responseTimeout: TimeInterval) throws {
        let deadline = Date.now.addingTimeInterval(responseTimeout)
        guard !authenticationPasswordResolutionAttempted,
              let password = resolveDeferredAuthenticationPassword(deadline: deadline) else {
            return
        }
        authenticationPassword = password
        socketAuthenticated = false
        try authenticateIfNeeded(responseTimeout: responseTimeout, deadline: deadline)
    }
}
