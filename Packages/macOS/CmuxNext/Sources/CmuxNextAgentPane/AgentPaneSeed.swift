public import Foundation

/// What a new agent tab inherits from the tab it was opened from (#16620):
/// the directory its session starts in, and text the composer starts with.
/// The draft is only shown; the user sends it. A `prompt` is sent by itself
/// once the chat connects (onboarding's first task).
public nonisolated struct AgentPaneSeed: Sendable, Equatable {
    /// The new session's working directory (a terminal's cwd or worktree).
    public var cwd: String?
    /// The composer's first text (a selection, a page's title and URL).
    public var draft: String?
    /// The first prompt, sent without the user pressing Send.
    public var prompt: String?
    /// Where the page is shown when it is not a pane tab (the quick panel).
    public var surface: AgentPaneSurface?

    public init(cwd: String? = nil, draft: String? = nil, prompt: String? = nil, surface: AgentPaneSurface? = nil) {
        self.cwd = cwd
        self.draft = draft
        self.prompt = prompt
        self.surface = surface
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
    /// The seed's surface. Unlike the draft it holds for the page's whole
    /// life, after the chat has a session too.
    public private(set) var surface: AgentPaneSurface?

    public init(limit: Duration = .seconds(1), _ read: @escaping @MainActor @Sendable () async -> AgentPaneSeed?) {
        self.read = read
        self.limit = limit
    }

    public init(_ seed: AgentPaneSeed) {
        value = seed
        limit = .zero
        surface = seed.surface
    }

    /// The seed, read once. The draft and prompt are handed out only once,
    /// so a page that reloads before the first prompt does not get them twice.
    func take() async -> AgentPaneSeed? {
        if let read {
            self.read = nil
            value = await agentPaneFirst(within: limit, read)
            surface = value?.surface
        }
        let seed = value
        value?.draft = nil
        value?.prompt = nil
        return seed
    }
}

/// `read`'s answer, or nil once `limit` passes. A late answer is dropped
/// without being awaited (a hung page never answers), unlike a deadline
/// raced in a task group, which waits for its loser.
func agentPaneFirst<T: Sendable>(within limit: Duration, _ read: @escaping @MainActor @Sendable () async -> T?) async -> T? {
    await withCheckedContinuation { continuation in
        let once = AgentPaneResumeOnce()
        // task-owner: one-shot deadline for the read below; cancelled when the read answers first
        let deadline = Task { @MainActor in
            // wakeup-allow: one-shot deadline (a read from another tab or the page)
            try? await Task.sleep(for: limit)
            once.run { continuation.resume(returning: nil) }
        }
        // task-owner: one-shot read; a late answer is dropped
        Task { @MainActor in
            let value = await read()
            once.run { continuation.resume(returning: value) }
            deadline.cancel()
        }
    }
}
