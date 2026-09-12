import Foundation

enum CloudDiagnosticFailure: String, Codable, Sendable, Error {
    case authentication, sessionRefresh = "session_refresh", permission, plan
    case rateLimit = "rate_limit", conflict, network, timeout, server, response, unsupported
    case process, `protocol`, notFound = "not_found", resourceLimit = "resource_limit"
    case storage, cancelled, unknown

    var label: String {
        switch self {
        case .authentication, .sessionRefresh:
            return String(localized: "cloud.operation.failure.auth", defaultValue: "Cloud could not verify your session. Sign in again.")
        case .permission:
            return String(localized: "cloud.operation.failure.permission", defaultValue: "Cloud access was denied. Check your permissions.")
        case .plan:
            return String(localized: "cloud.operation.failure.plan", defaultValue: "Your plan does not allow this Cloud operation.")
        case .rateLimit:
            return String(localized: "cloud.operation.failure.rateLimit", defaultValue: "Cloud received too many requests. Wait before you retry.")
        case .network, .timeout:
            return String(localized: "cloud.operation.failure.network", defaultValue: "The Cloud connection did not complete. Check your connection and try again.")
        case .conflict:
            return String(localized: "cloud.operation.failure.conflict", defaultValue: "Another operation changed this machine. Refresh its state.")
        case .notFound:
            return String(localized: "cloud.operation.failure.notFound", defaultValue: "The Cloud resource is no longer available. Refresh the machine list.")
        case .unsupported:
            return String(localized: "cloud.operation.failure.unsupported", defaultValue: "This Cloud operation is not supported. Check for an update.")
        case .cancelled:
            return String(localized: "cloud.operation.failure.cancelled", defaultValue: "Operation cancelled")
        case .server, .response, .process, .protocol, .resourceLimit, .storage, .unknown:
            return String(localized: "cloud.operation.failure.other", defaultValue: "The Cloud operation failed. Copy the diagnostic reference if the problem continues.")
        }
    }

    static func classify(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            return error.code == .timedOut ? .timeout : .network
        }
        if let error = error as? VMClientError {
            switch error {
            case .notSignedIn: return .authentication
            case .sessionRefreshFailed: return .sessionRefresh
            case .backendUnreachable: return .network
            case .malformedResponse: return .response
            case .disabledByManagedPolicy: return .permission
            case .lifecycleUnsupported: return .unsupported
            case .httpStatus(let status, _): return classify(status: status)
            }
        }
        if let error = error as? CloudMachineLink.LinkError {
            switch error {
            case .timedOut: return .timeout
            case .inputTooLarge: return .resourceLimit
            case .clientMissing, .spawnFailed, .exited: return .process
            }
        }
        if error is CloudMachineLinkManager.ManagerError { return .connectFailure(error) }
        if error is DecodingError { return .response }
        return .unknown
    }

    private static func connectFailure(_ error: Error) -> Self {
        guard let error = error as? CloudMachineLinkManager.ManagerError else { return .unknown }
        switch error {
        case .clientMissing, .wireGuardHubMissing: return .process
        case .wireGuardHubUnsupported: return .unsupported
        case .privateRouteRequired, .retryLater: return .network
        }
    }

    static func classify(status: Int) -> Self {
        switch status {
        case 401: return .authentication
        case 402: return .plan
        case 403: return .permission
        case 404: return .notFound
        case 408, 504: return .timeout
        case 409: return .conflict
        case 429: return .rateLimit
        case 501: return .unsupported
        case 500...599: return .server
        default: return .response
        }
    }
}
