import CmuxNextCompat
public import CmuxNextSettings
public import CmuxNextWakeups
public import Foundation

/// Unacknowledged inline queue edits, independently of acpmux's queued prompt. Only attachment
/// references live here; acpmux retains their bytes. All disk work runs in one ordered queue.
@MainActor
public final class AgentPaneQueuedEdits {
    public static let fileName = "agent-queued-edits.json"
    static let methods: Set<String> = ["chat.queuedEditDrafts.get", "chat.queuedEditDrafts.set", "chat.queuedEditDrafts.clear"]
    private let file: URL?
    private let background: BackgroundWork
    private var tail: Task<Void, Never>?

    nonisolated struct Draft: Codable, Equatable, Sendable {
        var revision: String
        var originalPrompt: String
        var originalImages: [String]
        var text: String
        var droppedImages: [String]
    }

    public init(directory: URL?, work: BackgroundWork = BackgroundWork()) {
        background = work
        file = directory?.appending(path: Self.fileName)
    }

    public func read(session: String) async throws -> JSONValue {
        try await queued { file in
            let drafts = try Self.load(file)[session] ?? [:]
            let data = try JSONEncoder().encode(drafts)
            return try JSONValue.parse(data)
        }
    }

    public func set(session: String, prompt: String, value: JSONValue) async throws {
        try await queued { file in
            let data = Data(value.compactText.utf8)
            let draft = try JSONDecoder().decode(Draft.self, from: data)
            guard !draft.revision.isEmpty, draft.text.utf8.count <= 4_000_000,
                  draft.originalPrompt.utf8.count <= 4_000_000,
                  draft.originalImages.count <= 1_000, draft.droppedImages.count <= 1_000 else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            var saved = try Self.load(file)
            saved[session, default: [:]][prompt] = draft
            try Self.save(saved, file)
        }
    }

    /// An old RPC reply may only clear the edit it acknowledged, never newer typing.
    public func clear(session: String, prompt: String, revision: String) async throws {
        try await queued { file in
            var saved = try Self.load(file)
            guard saved[session]?[prompt]?.revision == revision else { return }
            saved[session]?[prompt] = nil
            if saved[session]?.isEmpty == true { saved[session] = nil }
            try Self.save(saved, file)
        }
    }

    private func queued<T: Sendable>(_ work: @escaping @Sendable (URL?) throws -> T) async throws -> T {
        let previous = tail, file = file, background = background
        // task-owner: the request awaits task, and tail orders every later request after it.
        let task = Task(priority: .medium) {
            await previous?.value
            return try await background.run(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { try work(file) }
        }
        let done = Task(priority: .medium) { _ = try? await task.value }
        tail = done
        defer { if tail == done { tail = nil } }
        return try await task.value
    }

    private nonisolated static func load(_ file: URL?) throws -> [String: [String: Draft]] {
        guard let file, FileManager.checked.fileExists(atPath: file.path) else { return [:] }
        // concurrency-allow: the store serializes this read off the main actor
        return try JSONDecoder().decode([String: [String: Draft]].self, from: Data(blockingContentsOf: file))
    }

    private nonisolated static func save(_ saved: [String: [String: Draft]], _ file: URL?) throws {
        guard let file else { return }
        // Claim this artifact before a clear can remove it. Migration retries then preserve the
        // current writer's empty result instead of copying a stale legacy queue back into place.
        try DraftStateMigration.markCurrent([Self.fileName], in: file.deletingLastPathComponent())
        let manager = FileManager.checked
        if saved.isEmpty {
            if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
            return
        }
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(saved).blockingWrite(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
