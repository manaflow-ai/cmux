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
    /// Who seeded ``prompt``. Only a person's own action or onboarding's first task gets the
    /// single-use gesture ticket the prompt needs to go out by itself (cx-k21v gap 4, chief:
    /// person only); a prompt seeded by the CLI, MCP, a script or another client gets none, so
    /// the relay refuses it (`transport.gesture_required`) and the prompt waits in the composer.
    public var promptBy: PromptBy
    /// An outside chat to resume instead of starting a new one. Kept across
    /// page reloads: acpmux adopts one id into one session.
    public var adopt: AgentPaneAdopt?
    /// Where the page is shown when it is not a pane tab (the quick panel).
    public var surface: AgentPaneSurface?
    /// The harness a new chat starts on (`newTab.submit --agent`); nil is the default.
    public var harness: String?
    /// A chat that opened without its folder: the page explains it and offers Choose Folder.
    public var folderNeeded: AgentPaneFolderNeeded?
    /// The device-wide chat (its index key, `harness:id`) whose past turns a new chat shows
    /// read-only until it has a session (cx-khns1); an adopted chat shows them while its folder's
    /// trust question holds the replay. Kept across page reloads.
    public var pastChat: String?
    /// The page opens on its Harnesses page (Integrate a Harness…, cx-uj5g8). Handed out once.
    public var showsHarnesses: Bool
    /// A Sandboxed send that already ended, shown by this new page as its own (a Run notification's
    /// click, ``AgentPaneSandboxRuns``).
    public var sandboxResult: SandboxResult?

    /// An ended Sandboxed send: its task, attempt key and final receipt (`{"receipt": …}` as JSON).
    public nonisolated struct SandboxResult: Sendable, Equatable {
        public var task: String
        public var key: String
        public var card: Data?
        public init(task: String, key: String, card: Data?) { (self.task, self.key, self.card) = (task, key, card) }
    }

    /// Who seeded a prompt that goes out by itself.
    public nonisolated enum PromptBy: Sendable, Equatable {
        /// A person's own action in this app (`ActionOrigin.user`).
        case person
        /// Onboarding's first task.
        case onboarding
        /// The CLI, MCP, a script, a page or another client: no ticket.
        case automation

        /// Whether the prompt gets the ticket that lets it go out by itself.
        public var sendsBySelf: Bool { self != .automation }
    }

    public init(cwd: String? = nil, draft: String? = nil, prompt: String? = nil, promptBy: PromptBy = .automation,
                adopt: AgentPaneAdopt? = nil, surface: AgentPaneSurface? = nil, harness: String? = nil,
                folderNeeded: AgentPaneFolderNeeded? = nil, pastChat: String? = nil, showsHarnesses: Bool = false) {
        self.promptBy = promptBy
        self.showsHarnesses = showsHarnesses
        self.folderNeeded = folderNeeded
        self.pastChat = pastChat
        self.cwd = cwd
        self.draft = draft
        self.prompt = prompt
        self.adopt = adopt
        self.surface = surface
        self.harness = harness
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
    /// The missing folder this pane's chat waits for (cx-nn3e.1), until a pick works.
    public internal(set) var folderNeeded: AgentPaneFolderNeeded?
    /// The chat was opened for its workspace (Cmd-I's chat dock, cx-ihyx2): until the chat has a
    /// session the page adds the workspace context to its first prompt, hidden from the
    /// transcript (`_meta.acpmux.context`). Held apart from the read seed, which a slow read drops.
    public var workspaceContext = false
    /// A Sandboxed send that already ended, shown by this new page (``AgentPaneSeed/sandboxResult``).
    public var sandboxResult: AgentPaneSeed.SandboxResult?

    public init(limit: Duration = .seconds(1), _ read: @escaping @MainActor @Sendable () async -> AgentPaneSeed?) {
        self.read = read
        self.limit = limit
    }

    /// The seed holds a folder and nothing else (a new workspace's first New Tab page): a page
    /// that takes its folder from its New Tab context can stand in for it.
    public var holdsOnlyFolder: Bool {
        guard read == nil, sandboxResult == nil else { return false }
        guard let value else { return true }
        return value.draft == nil && value.prompt == nil && value.adopt == nil && value.surface == nil
            && value.harness == nil && value.folderNeeded == nil && value.pastChat == nil && !value.showsHarnesses
    }

    /// The seed names a chat of this Mac: an outside chat it resumes (`adopt`) or a past chat of
    /// this Mac's chat list (`pastChat`). Such a seed never opens in a tab of another machine
    /// (cx-k21v). A seed still to be read (another tab's selection) names neither.
    public var namesLocalChat: Bool {
        guard read == nil, let value else { return false }
        return value.adopt != nil || value.pastChat != nil
    }

    public init(_ seed: AgentPaneSeed) {
        value = seed
        limit = .zero
        surface = seed.surface
        sandboxResult = seed.sandboxResult
    }

    /// The seed without taking its draft or prompt: where a chat on another machine starts
    /// (its folder and harness) before the page's handshake takes the rest.
    public func peek() async -> AgentPaneSeed? {
        if let read {
            self.read = nil
            value = await agentPaneFirst(within: limit, read)
            surface = value?.surface
        }
        return value
    }

    /// The seed, read once. The draft and prompt are handed out only once,
    /// so a page that reloads before the first prompt does not get them twice.
    public func take() async -> AgentPaneSeed? {
        if let read {
            self.read = nil
            value = await agentPaneFirst(within: limit, read)
            surface = value?.surface
        }
        let seed = value
        value?.draft = nil
        value?.prompt = nil
        value?.showsHarnesses = false
        // A missing folder is taken once; Choose Folder changes or clears it (cx-nn3e.1).
        if let needed = value?.folderNeeded {
            folderNeeded = needed
            value?.folderNeeded = nil
        }
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
