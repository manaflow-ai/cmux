import Foundation

enum CloudOperationKind: String, Codable, Sendable {
    case create, open, list, status, stats, rename, delete, pause, resume
    case snapshot, fork, restore, resize, exec, port, publication, domain
    case base, session, workspace, terminal, file, environment, tunnel
    case connect, refresh, notification, agent, unknown

    var label: String {
        switch self {
        case .create: return String(localized: "cloud.operation.kind.create", defaultValue: "Create machine")
        case .open: return String(localized: "cloud.operation.kind.open", defaultValue: "Open machine")
        case .list, .status, .stats, .refresh: return String(localized: "cloud.operation.kind.refresh", defaultValue: "Refresh machines")
        case .rename: return String(localized: "cloud.operation.kind.rename", defaultValue: "Rename machine")
        case .delete: return String(localized: "cloud.operation.kind.delete", defaultValue: "Delete machine")
        case .pause: return String(localized: "cloud.operation.kind.pause", defaultValue: "Pause machine")
        case .resume: return String(localized: "cloud.operation.kind.resume", defaultValue: "Resume machine")
        case .snapshot: return String(localized: "cloud.operation.kind.snapshot", defaultValue: "Save snapshot")
        case .fork: return String(localized: "cloud.operation.kind.fork", defaultValue: "Copy machine")
        case .restore: return String(localized: "cloud.operation.kind.restore", defaultValue: "Restore machine")
        case .resize: return String(localized: "cloud.operation.kind.resize", defaultValue: "Resize machine")
        case .exec: return String(localized: "cloud.operation.kind.exec", defaultValue: "Run machine command")
        case .port: return String(localized: "cloud.operation.kind.port", defaultValue: "Open port")
        case .publication, .domain: return String(localized: "cloud.operation.kind.publication", defaultValue: "Manage publication")
        case .base: return String(localized: "cloud.operation.kind.base", defaultValue: "Prepare base")
        case .session, .workspace: return String(localized: "cloud.operation.kind.workspace", defaultValue: "Open workspace")
        case .terminal: return String(localized: "cloud.operation.kind.terminal", defaultValue: "Open terminal")
        case .file: return String(localized: "cloud.operation.kind.file", defaultValue: "Transfer files")
        case .environment: return String(localized: "cloud.operation.kind.environment", defaultValue: "Prepare environment")
        case .tunnel, .connect: return String(localized: "cloud.operation.kind.connect", defaultValue: "Connect to machine")
        case .notification: return String(localized: "cloud.operation.kind.notification", defaultValue: "Update notifications")
        case .agent: return String(localized: "cloud.operation.kind.agent", defaultValue: "Start agent")
        case .unknown: return String(localized: "cloud.operation.kind.unknown", defaultValue: "Cloud operation")
        }
    }

    static func resolve(_ value: String) -> Self {
        let words = value.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        // Prefer the final structured operation token. This keeps `create snapshot`
        // as `.snapshot` and prevents an earlier verb from hiding the resource kind.
        for word in words.reversed() {
            if let kind = Self(rawValue: word) { return kind }
        }
        if words.contains("new") || words.contains("create") { return .create }
        if words.contains("rm") || words.contains("destroy") { return .delete }
        if words.contains("attach") || words.contains("shell") || words.contains("desktop") { return .open }
        return .unknown
    }
}
