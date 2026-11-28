import Foundation

struct SSHPTYTerminalReadinessReport: Sendable {
    private enum DeliveryOutcome {
        case acknowledged
        case transientFailure
        case permanentRejection
    }

    private static let permanentV2RejectionCodes: Set<String> = [
        "auth_failed",
        "auth_required",
        "auth_unconfigured",
        "forbidden",
        "invalid_params",
        "invalid_request",
        "invalid_utf8",
        "method_not_found",
        "not_found",
        "not_supported",
        "permission_denied",
        "pty_lifecycle_closed",
        "stale_state",
        "unauthorized",
        "unsupported",
        "validation_failed",
        "workspace_not_found",
    ]

    let socketPath: String
    let explicitPassword: String?
    let params: [String: String]
    let attemptTimeout: TimeInterval
    let retryDelay: TimeInterval
    let maximumRetryDelay: TimeInterval

    func deliverUntilAcknowledged() async {
        let initialRetryDelay = max(0, retryDelay)
        let retryDelayCap = max(initialRetryDelay, maximumRetryDelay)
        var nextRetryDelay = initialRetryDelay
        let clock = ContinuousClock()
        while !Task.isCancelled {
            switch deliverOnce() {
            case .acknowledged, .permanentRejection:
                return
            case .transientFailure:
                break
            }
            do {
                try await clock.sleep(for: .seconds(nextRetryDelay))
            } catch {
                return
            }
            nextRetryDelay = min(retryDelayCap, nextRetryDelay * 2)
        }
    }

    private func deliverOnce() -> DeliveryOutcome {
        let deadline = Date.now.addingTimeInterval(attemptTimeout)
        let reportingClient = SocketClient(path: socketPath)
        defer { reportingClient.close() }
        do {
            try reportingClient.connectWithoutRetry(responseTimeout: attemptTimeout)
            let authenticationTimeout = deadline.timeIntervalSinceNow
            guard authenticationTimeout > 0 else { return .transientFailure }
            try CMUXCLI.authenticateSocketClientIfNeeded(
                reportingClient,
                explicitPassword: explicitPassword,
                socketPath: socketPath,
                responseTimeout: authenticationTimeout,
                deadline: deadline
            )
            let reportTimeout = deadline.timeIntervalSinceNow
            guard reportTimeout > 0 else { return .transientFailure }
            let jsonParams = params.reduce(into: [String: Any]()) {
                $0[$1.key] = $1.value
            }
            _ = try reportingClient.sendV2(
                method: "workspace.remote.terminal_session_connected",
                params: jsonParams,
                responseTimeout: reportTimeout
            )
            return .acknowledged
        } catch let error as CLIError {
            if error.message.hasPrefix("ERROR:") ||
                error.v2Code.map(Self.permanentV2RejectionCodes.contains) == true {
                return .permanentRejection
            }
            return .transientFailure
        } catch {
            return .transientFailure
        }
    }
}
