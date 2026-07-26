import Foundation

/// Loads Claude Code's authoritative task snapshot for one session.
///
/// Claude task tools mutate individual JSON files. Consumers should load the
/// complete directory after each task-tool event instead of accumulating
/// partial mutations in memory.
public struct ClaudeTaskSnapshotLoader {
    /// The directory containing Claude's per-session task directories.
    public let tasksRootURL: URL

    private let fileManager: FileManager

    /// Creates a loader rooted at a specific Claude tasks directory.
    ///
    /// - Parameters:
    ///   - tasksRootURL: The directory that contains session task directories.
    ///   - fileManager: The filesystem implementation used to read snapshots.
    public init(tasksRootURL: URL, fileManager: FileManager = .default) {
        self.tasksRootURL = tasksRootURL
        self.fileManager = fileManager
    }

    /// Resolves Claude's task root from its process environment.
    ///
    /// `CLAUDE_CONFIG_DIR` wins when configured; otherwise tasks are read from
    /// `$HOME/.claude/tasks`. An absent or empty hook `HOME` falls back to the
    /// supplied home directory.
    ///
    /// - Parameters:
    ///   - environment: The Claude hook process environment.
    ///   - homeDirectoryURL: The fallback hook-user home directory.
    /// - Returns: The configured Claude tasks directory.
    public static func tasksRootURL(
        environment: [String: String],
        homeDirectoryURL: URL
    ) -> URL {
        let configuredDirectory = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentHome = Self.nonEmpty(environment["HOME"]).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let hookHomeURL = environmentHome ?? homeDirectoryURL
        let configURL: URL
        if let configuredDirectory, !configuredDirectory.isEmpty {
            if configuredDirectory == "~" {
                configURL = hookHomeURL
            } else if configuredDirectory.hasPrefix("~/") {
                configURL = hookHomeURL.appendingPathComponent(
                    String(configuredDirectory.dropFirst(2)),
                    isDirectory: true
                )
            } else {
                configURL = URL(fileURLWithPath: configuredDirectory, isDirectory: true)
            }
        } else {
            configURL = hookHomeURL.appendingPathComponent(".claude", isDirectory: true)
        }
        return configURL.appendingPathComponent("tasks", isDirectory: true)
    }

    /// Reads and canonicalizes every task currently persisted for a session.
    ///
    /// Both `<tasks>/<session-id>` and the older
    /// `<tasks>/session-<session-id>` directory layouts are supported.
    /// Malformed task files and tasks marked `deleted` are omitted.
    ///
    /// - Parameter sessionID: Claude's hook `session_id` value.
    /// - Returns: The complete live task snapshot in stable task-id order.
    /// - Throws: A filesystem error while enumerating an existing session directory.
    public func load(sessionID: String) throws -> [WorkstreamTaskTodo] {
        guard let sessionDirectory = sessionDirectoryURL(sessionID: sessionID) else {
            return []
        }
        let fileURLs = try fileManager.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        let todos = fileURLs.compactMap { fileURL -> WorkstreamTaskTodo? in
            guard fileURL.pathExtension.lowercased() == "json",
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: fileURL),
                  let record = try? decoder.decode(TaskRecord.self, from: data),
                  let state = record.canonicalState,
                  let content = Self.nonEmpty(record.subject) else {
                return nil
            }
            return WorkstreamTaskTodo(
                id: record.id,
                content: content,
                activeForm: Self.nonEmpty(record.activeForm),
                state: state
            )
        }
        return todos.sorted(by: Self.taskSort)
    }

    private func sessionDirectoryURL(sessionID: String) -> URL? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\0") else {
            return nil
        }
        let bareID = trimmed.hasPrefix("session-")
            ? String(trimmed.dropFirst("session-".count))
            : trimmed
        let names = [trimmed, bareID, "session-\(bareID)"]
        var seen = Set<String>()
        for name in names where !name.isEmpty && seen.insert(name).inserted {
            let candidate = tasksRootURL.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func taskSort(_ lhs: WorkstreamTaskTodo, _ rhs: WorkstreamTaskTodo) -> Bool {
        if let leftNumber = Int(lhs.id), let rightNumber = Int(rhs.id), leftNumber != rightNumber {
            return leftNumber < rightNumber
        }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    private struct TaskRecord: Decodable {
        let id: String
        let subject: String
        let activeForm: String?
        let status: String

        var canonicalState: WorkstreamTaskTodo.State? {
            switch status {
            case "pending": .pending
            case "in_progress": .inProgress
            case "completed": .completed
            case "deleted": nil
            default: nil
            }
        }
    }
}
