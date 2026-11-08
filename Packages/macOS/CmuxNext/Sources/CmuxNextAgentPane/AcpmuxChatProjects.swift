public import CmuxNextDaemon
public import Foundation

/// acpmux's chat index grouped into each harness's project folders (`_acpmux/chat_projects`):
/// every absolute chat folder with the time of its newest chat. acpmux groups its own index, so the
/// app reads a few rows, never every chat (P-RUST: no whole-index mirror in Swift).
public nonisolated struct AcpmuxChatProjects: Sendable, Equatable {
    public nonisolated struct Project: Sendable, Equatable {
        public let harness: String
        public let path: String
        public let lastUsedMs: Int64

        public init(harness: String, path: String, lastUsedMs: Int64) {
            self.harness = harness
            self.path = path
            self.lastUsedMs = lastUsedMs
        }
    }

    /// The first scan finished.
    public var ready: Bool
    /// Chats are on (`agents.chats.enabled`).
    public var enabled: Bool
    /// By harness, then path.
    public var projects: [Project]

    public init(ready: Bool, enabled: Bool, projects: [Project]) {
        self.ready = ready
        self.enabled = enabled
        self.projects = projects
    }

    init(result: [String: Any]) {
        let rows = result["projects"] as? [[String: Any]] ?? []
        self.init(ready: result["ready"] as? Bool ?? false, enabled: result["enabled"] as? Bool ?? true,
                  projects: rows.compactMap { row in
                      guard let harness = row["harness"] as? String, let path = row["path"] as? String,
                            let used = (row["lastUsedMs"] as? NSNumber)?.int64Value else { return nil }
                      return Project(harness: harness, path: path, lastUsedMs: used)
                  })
    }
}

extension AcpmuxChatProjects {
    /// `_acpmux/chat_projects` from the daemon at `socketPath`; the socket exchange and the decode
    /// run off the caller's actor. No reply cap of its own: the list is one row per chat folder and
    /// a person's folder count has no bound here (the daemon's frame limit still holds), and the
    /// deadline is the status client's usual one for a local request.
    @concurrent public static func read(socketPath: String, deadline: Duration = .seconds(5)) async throws -> AcpmuxChatProjects {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/chat_projects", deadline: deadline,
                                                       limit: .max)
        return AcpmuxChatProjects(result: result)
    }
}

extension AcpmuxChatProjects {
    /// One harness's projects: each cwd with its newest chat.
    public nonisolated struct Batch: Equatable, Sendable {
        public nonisolated struct Entry: Equatable, Sendable {
            public let path: String
            public let lastUsedMs: Int64
        }

        public let source: String
        public let entries: [Entry]

        public var fingerprint: Int {
            var hasher = Hasher()
            for entry in entries {
                hasher.combine(entry.path)
                hasher.combine(entry.lastUsedMs)
            }
            return hasher.finalize()
        }

        public var entriesJSON: [JSONValue] {
            entries.map { .object(["path": .string($0.path), "last_used_ms": .string(String($0.lastUsedMs))]) }
        }
    }

    /// The batches for acpmux's grouped `projects`, leaving out each harness whose fingerprint is
    /// already `sent`. A harness in `sent` with no project left gets an empty complete list. Sorted
    /// by harness, entries by path. Nothing while the index is not ready or chats are off: a
    /// partial list sent as complete would drop the harness from its projects.
    public func batches(sent: [String: Int]) -> [Batch] {
        guard ready, enabled else { return [] }
        var bySource: [String: [Batch.Entry]] = [:]
        for project in projects {
            bySource[project.harness, default: []].append(Batch.Entry(path: project.path, lastUsedMs: project.lastUsedMs))
        }
        for source in sent.keys where bySource[source] == nil { bySource[source] = [] }
        return bySource.keys.sorted().compactMap { source in
            let entries = (bySource[source] ?? []).sorted { $0.path < $1.path }
            let batch = Batch(source: source, entries: entries)
            return sent[source] == batch.fingerprint ? nil : batch
        }
    }
}
