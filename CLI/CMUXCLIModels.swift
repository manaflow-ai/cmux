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
    /// Optional fields merged into a command-owned structured error envelope.
    let structuredFields: CLIErrorStructuredFields?

    init(
        message: String,
        exitCode: Int32 = 1,
        v2Code: String? = nil,
        structuredFields: CLIErrorStructuredFields? = nil
    ) {
        self.message = message
        self.exitCode = exitCode
        self.v2Code = v2Code
        self.structuredFields = structuredFields
    }

    var description: String { message }
}

struct CLIErrorStructuredFields: Sendable {
    var provider: String? = nil
    var conflictingProvider: String? = nil
    var path: String? = nil
    var scope: String? = nil
    var sessionID: String? = nil
    var observedBytes: Int64? = nil
    var maximumBytes: Int64? = nil
    var observedCount: Int64? = nil
    var maximumCount: Int64? = nil
    var guidance: String? = nil
    var recoveryAction: String? = nil
    var canonicalPath: String? = nil
    var limit: Int? = nil
    var observedAtLeast: Int? = nil
    var maximumRecordBytes: Int? = nil

    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        object["provider"] = (provider as Any?) ?? NSNull()
        if let conflictingProvider { object["conflicting_provider"] = conflictingProvider }
        object["path"] = (path as Any?) ?? NSNull()
        object["scope"] = (scope as Any?) ?? NSNull()
        object["session_id"] = (sessionID as Any?) ?? NSNull()
        object["observed_bytes"] = (observedBytes as Any?) ?? NSNull()
        object["maximum_bytes"] = (maximumBytes as Any?) ?? NSNull()
        object["observed_count"] = (observedCount as Any?) ?? NSNull()
        object["maximum_count"] = (maximumCount as Any?) ?? NSNull()
        if let guidance { object["guidance"] = guidance }
        if let recoveryAction { object["recovery_action"] = recoveryAction }
        if let canonicalPath { object["canonical_path"] = canonicalPath }
        if let limit { object["limit"] = limit }
        if let observedAtLeast { object["observed_at_least"] = observedAtLeast }
        if let maximumRecordBytes { object["maximum_record_bytes"] = maximumRecordBytes }
        return object
    }
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
