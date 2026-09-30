import Foundation
import OSLog

nonisolated private let claudeHookSessionStoreLogger = Logger(
    subsystem: "com.cmuxterm.cli",
    category: "AgentHookStore"
)

struct ClaudeHookSessionStoreFile: Codable {
    struct DecodeDiagnostics: Equatable {
        fileprivate(set) var droppedPaths: [String] = []

        var droppedCount: Int { droppedPaths.count }
    }

    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
    // Superseded records stay durable for retry without remaining visible to
    // store consumers as simultaneously live session claimants.
    var pendingSupersededSessionCleanup: [String: ClaudeHookSessionRecord] = [:]
    var activeSessionsByWorkspace: [String: ClaudeHookActiveSessionRecord] = [:]
    // The pane-scoped active boundary. The workspace slot only remembers ONE
    // active session, so once another pane promotes (e.g. a forked conversation
    // in a split), it can no longer prove that a late hook from a superseded
    // session in this pane is stale. Keyed by surface id.
    // https://github.com/manaflow-ai/cmux/issues/5908
    var activeSessionsBySurface: [String: ClaudeHookActiveSessionRecord] = [:]
    var agentHookFailureReportTimestamps: [String: TimeInterval] = [:]
    /// Bounded lookup index for Cursor approvals, keyed by stable surface id.
    var pendingCursorApprovalSessionsBySurface: [String: [String]] = [:]
    /// Exact pending-session count for each stable surface identity. The ID
    /// list is capped, so this count preserves sibling detection when the cap
    /// is exceeded.
    var pendingCursorApprovalSessionCountsBySurface: [String: Int] = [:]
    /// Surfaces whose capped ID list has overflowed. The flag remains set until
    /// the count reaches zero so an omitted session cannot be mistaken for the
    /// current completion after the retained IDs drain.
    var pendingCursorApprovalSurfaceOverflow: [String: Bool] = [:]
    var pendingCursorApprovalIndexInitialized: Bool = false
    private(set) var decodeDiagnostics = DecodeDiagnostics()

    enum CodingKeys: String, CodingKey {
        case version
        case sessions
        case pendingSupersededSessionCleanup
        case activeSessionsByWorkspace
        case activeSessionsBySurface
        case agentHookFailureReportTimestamps
        case pendingCursorApprovalSessionsBySurface
        case pendingCursorApprovalSessionCountsBySurface
        case pendingCursorApprovalSurfaceOverflow
        case pendingCursorApprovalIndexInitialized
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var droppedPaths: [String] = []
        version = Self.decodeScalar(
            Int.self,
            from: container,
            forKey: .version,
            defaultValue: 1,
            droppedPaths: &droppedPaths
        )
        sessions = Self.decodeDictionary(
            ClaudeHookSessionRecord.self,
            from: container,
            forKey: .sessions,
            droppedPaths: &droppedPaths
        )
        pendingSupersededSessionCleanup = Self.decodeDictionary(
            ClaudeHookSessionRecord.self,
            from: container,
            forKey: .pendingSupersededSessionCleanup,
            droppedPaths: &droppedPaths
        )
        activeSessionsByWorkspace = Self.decodeDictionary(
            ClaudeHookActiveSessionRecord.self,
            from: container,
            forKey: .activeSessionsByWorkspace,
            droppedPaths: &droppedPaths
        )
        activeSessionsBySurface = Self.decodeDictionary(
            ClaudeHookActiveSessionRecord.self,
            from: container,
            forKey: .activeSessionsBySurface,
            droppedPaths: &droppedPaths
        )
        agentHookFailureReportTimestamps = Self.decodeDictionary(
            TimeInterval.self,
            from: container,
            forKey: .agentHookFailureReportTimestamps,
            droppedPaths: &droppedPaths
        )
        pendingCursorApprovalSessionsBySurface = Self.decodeDictionary(
            [String].self,
            from: container,
            forKey: .pendingCursorApprovalSessionsBySurface,
            droppedPaths: &droppedPaths
        )
        pendingCursorApprovalSessionCountsBySurface = Self.decodeDictionary(
            Int.self,
            from: container,
            forKey: .pendingCursorApprovalSessionCountsBySurface,
            droppedPaths: &droppedPaths
        )
        pendingCursorApprovalSurfaceOverflow = Self.decodeDictionary(
            Bool.self,
            from: container,
            forKey: .pendingCursorApprovalSurfaceOverflow,
            droppedPaths: &droppedPaths
        )
        pendingCursorApprovalIndexInitialized = Self.decodeScalar(
            Bool.self,
            from: container,
            forKey: .pendingCursorApprovalIndexInitialized,
            defaultValue: false,
            droppedPaths: &droppedPaths
        )
        decodeDiagnostics = DecodeDiagnostics(droppedPaths: droppedPaths)
        if !droppedPaths.isEmpty {
            claudeHookSessionStoreLogger.error(
                "Recovered hook session state after dropping malformed entries count=\(droppedPaths.count, privacy: .public)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(sessions, forKey: .sessions)
        if !pendingSupersededSessionCleanup.isEmpty {
            try container.encode(pendingSupersededSessionCleanup, forKey: .pendingSupersededSessionCleanup)
        }
        if !activeSessionsByWorkspace.isEmpty {
            try container.encode(activeSessionsByWorkspace, forKey: .activeSessionsByWorkspace)
        }
        if !activeSessionsBySurface.isEmpty {
            try container.encode(activeSessionsBySurface, forKey: .activeSessionsBySurface)
        }
        if !agentHookFailureReportTimestamps.isEmpty {
            try container.encode(agentHookFailureReportTimestamps, forKey: .agentHookFailureReportTimestamps)
        }
        if !pendingCursorApprovalSessionsBySurface.isEmpty {
            try container.encode(
                pendingCursorApprovalSessionsBySurface,
                forKey: .pendingCursorApprovalSessionsBySurface
            )
        }
        if !pendingCursorApprovalSessionCountsBySurface.isEmpty {
            try container.encode(
                pendingCursorApprovalSessionCountsBySurface,
                forKey: .pendingCursorApprovalSessionCountsBySurface
            )
        }
        if !pendingCursorApprovalSurfaceOverflow.isEmpty {
            try container.encode(
                pendingCursorApprovalSurfaceOverflow,
                forKey: .pendingCursorApprovalSurfaceOverflow
            )
        }
        if pendingCursorApprovalIndexInitialized {
            try container.encode(true, forKey: .pendingCursorApprovalIndexInitialized)
        }
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private static func decodeScalar<Value: Decodable>(
        _ type: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        defaultValue: Value,
        droppedPaths: inout [String]
    ) -> Value {
        do {
            return try container.decodeIfPresent(type, forKey: key) ?? defaultValue
        } catch {
            droppedPaths.append(key.stringValue)
            return defaultValue
        }
    }

    private static func decodeDictionary<Value: Decodable>(
        _ type: Value.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        droppedPaths: inout [String]
    ) -> [String: Value] {
        guard container.contains(key) else { return [:] }
        let nested: KeyedDecodingContainer<AnyCodingKey>
        do {
            nested = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
        } catch {
            droppedPaths.append(key.stringValue)
            return [:]
        }

        var decoded: [String: Value] = [:]
        for nestedKey in nested.allKeys {
            do {
                decoded[nestedKey.stringValue] = try nested.decode(Value.self, forKey: nestedKey)
            } catch {
                droppedPaths.append("\(key.stringValue).\(nestedKey.stringValue)")
            }
        }
        return decoded
    }
}
