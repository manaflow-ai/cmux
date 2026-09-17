import Foundation

enum CloudOperationPhase: String, Codable, Sendable {
    case operation, authentication, request, retryWait = "retry_wait", provider, database
    case tunnel, route, process, connect, snapshot, materialize, ready, recovery
    case file, environment, port, notification, cleanup, export

    var label: String {
        switch self {
        case .operation: return String(localized: "cloud.operation.phase.operation", defaultValue: "Starting Cloud operation")
        case .authentication: return String(localized: "cloud.operation.phase.authentication", defaultValue: "Checking your session")
        case .request: return String(localized: "cloud.operation.phase.request", defaultValue: "Waiting for Cloud service")
        case .retryWait: return String(localized: "cloud.operation.phase.retry", defaultValue: "Waiting to retry")
        case .provider: return String(localized: "cloud.operation.phase.provider", defaultValue: "Preparing machine")
        case .database: return String(localized: "cloud.operation.phase.database", defaultValue: "Saving machine state")
        case .tunnel: return String(localized: "cloud.operation.phase.tunnel", defaultValue: "Starting private connection")
        case .route: return String(localized: "cloud.operation.phase.route", defaultValue: "Finding machine connection")
        case .process: return String(localized: "cloud.operation.phase.process", defaultValue: "Starting connection process")
        case .connect: return String(localized: "cloud.operation.phase.connect", defaultValue: "Connecting to machine")
        case .snapshot: return String(localized: "cloud.operation.phase.snapshot", defaultValue: "Loading machine state")
        case .materialize: return String(localized: "cloud.operation.phase.materialize", defaultValue: "Opening workspace")
        case .ready: return String(localized: "cloud.operation.phase.ready", defaultValue: "Waiting for terminal")
        case .recovery: return String(localized: "cloud.operation.phase.recovery", defaultValue: "Restoring connection")
        case .file: return String(localized: "cloud.operation.phase.file", defaultValue: "Transferring files")
        case .environment: return String(localized: "cloud.operation.phase.environment", defaultValue: "Preparing environment")
        case .port: return String(localized: "cloud.operation.phase.port", defaultValue: "Opening port")
        case .notification: return String(localized: "cloud.operation.phase.notification", defaultValue: "Updating notifications")
        case .cleanup: return String(localized: "cloud.operation.phase.cleanup", defaultValue: "Cleaning up")
        case .export: return String(localized: "cloud.operation.phase.export", defaultValue: "Sending diagnostics")
        }
    }
}
