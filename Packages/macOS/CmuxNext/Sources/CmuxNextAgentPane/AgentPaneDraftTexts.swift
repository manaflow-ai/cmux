import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation

/// The app-owned fallback for session text. Reads and writes share one ordered files queue.
@MainActor
public final class AgentPaneDraftTexts {
    public static let fileName = "agent-composer-drafts.json"
    private let file: URL?
    private let background: BackgroundWork
    private var tail: Task<Void, Never>?
    private var acceptsWrites = true

    public init(directory: URL?, work: BackgroundWork) {
        file = directory?.appending(path: Self.fileName)
        background = work
    }

    public func get(_ sessionId: String) async throws -> String? {
        try await queued { file in try Self.load(file)[sessionId] }
    }

    public func set(_ text: String, for sessionId: String) async throws {
        guard acceptsWrites else { return }
        try await queued { file in
            var drafts = try Self.load(file)
            guard drafts[sessionId] != text else { return }
            // Empty text is a tombstone: migration must never resurrect an older draft.
            drafts[sessionId] = text
            guard let file else { return }
            let manager = FileManager.checked
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(drafts).blockingWrite(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Waits for this store's ordered files writes without blocking the main actor.
    public func flush() async { await tail?.value }

    /// Called after a committed quit: page producers stop changing this store, then pending writes drain.
    public func finalizeForQuit() async {
        acceptsWrites = false
        await flush()
    }

    private func queued<T: Sendable>(_ work: @escaping @Sendable (URL?) throws -> T) async throws -> T {
        let previous = tail, file = file, background = background
        // task-owner: the request awaits task; tail orders every later request after it.
        let task = Task(priority: .medium) {
            await previous?.value
            return try await background.run(.userVisible, mayBlock: .files, shutdown: .blockShutdown) { try work(file) }
        }
        let done = Task(priority: .medium) { _ = try? await task.value }
        tail = done
        defer { if tail == done { tail = nil } }
        return try await task.value
    }

    private nonisolated static func load(_ file: URL?) throws -> [String: String] {
        guard let file, FileManager.checked.fileExists(atPath: file.path) else { return [:] }
        // concurrency-allow: queued reads run on the injected background files lane.
        return try JSONDecoder().decode([String: String].self, from: Data(blockingContentsOf: file))
    }
}
