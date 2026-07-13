import Foundation

struct CodexMonitorLeaseRecord: Codable {
    var leaseId: String
    var sessionId: String
    var turnId: String?
    var workspaceId: String
    var surfaceId: String?
    var createdAt: TimeInterval
    var retiredAt: TimeInterval?
}

enum CLIIDFormat: String {
    case refs
    case uuids
    case both

    static func parse(_ raw: String?) throws -> CLIIDFormat? {
        guard let raw else { return nil }
        guard let parsed = CLIIDFormat(rawValue: raw.lowercased()) else {
            throw CLIError(message: "--id-format must be one of: refs, uuids, both")
        }
        return parsed
    }
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    let exitCode: Int32
    /// Structured v2 protocol error code when the failure came from a v2 error response.
    let v2Code: String?

    init(message: String, exitCode: Int32 = 1, v2Code: String? = nil) {
        self.message = message
        self.exitCode = exitCode
        self.v2Code = v2Code
    }

    var description: String { message }
}

struct WindowInfo {
    let index: Int
    let id: String
    let key: Bool
    let selectedWorkspaceId: String?
    let workspaceCount: Int
}

struct NotificationInfo {
    let id: String
    let workspaceId: String
    let surfaceId: String?
    let isRead: Bool
    let title: String
    let subtitle: String
    let body: String
    let createdAt: String?
    let tabTitle: String?
}
