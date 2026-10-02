public import Foundation

/// What a new agent tab inherits from the tab it was opened from (#16620):
/// the directory its session starts in, and text the composer starts with.
/// The draft is only shown; the user sends it.
public nonisolated struct AgentPaneSeed: Sendable, Equatable {
    /// The new session's working directory (a terminal's cwd or worktree).
    public var cwd: String?
    /// The composer's first text (a selection, a page's title and URL).
    public var draft: String?

    public init(cwd: String? = nil, draft: String? = nil) {
        self.cwd = cwd
        self.draft = draft
    }
}

/// Reads a seed when the page first asks for its handshake. Reading can
/// wait on another tab (a page's selection), so it gets `limit`, and a seed
/// that misses it is dropped instead of holding the pane: the late read is
/// not awaited (a hung page never answers).
public final class AgentPaneSeedSource {
    private var read: (@MainActor @Sendable () async -> AgentPaneSeed?)?
    private var value: AgentPaneSeed?
    private let limit: Duration

    public init(limit: Duration = .seconds(1), _ read: @escaping @MainActor @Sendable () async -> AgentPaneSeed?) {
        self.read = read
        self.limit = limit
    }

    public init(_ seed: AgentPaneSeed) {
        value = seed
        limit = .zero
    }

    /// The seed, read once. The draft is handed out only once, so a page
    /// that reloads before the first prompt does not get it twice.
    func take() async -> AgentPaneSeed? {
        if let read {
            self.read = nil
            value = await Self.first(within: limit, read)
        }
        let seed = value
        value?.draft = nil
        return seed
    }

    private static func first(within limit: Duration, _ read: @escaping @MainActor @Sendable () async -> AgentPaneSeed?) async -> AgentPaneSeed? {
        await withCheckedContinuation { continuation in
            let once = AgentPaneResumeOnce()
            // task-owner: one-shot deadline for the read below; cancelled when the read answers first
            let deadline = Task { @MainActor in
                // wakeup-allow: one-shot deadline (agent tab seed)
                try? await Task.sleep(for: limit)
                once.run { continuation.resume(returning: nil) }
            }
            // task-owner: one-shot seed read; a late answer is dropped
            Task { @MainActor in
                let seed = await read()
                once.run { continuation.resume(returning: seed) }
                deadline.cancel()
            }
        }
    }
}
