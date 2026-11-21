public import CmuxNextSettings
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
    /// The seeded prompt's composer attachments, with any file paths already on its machine.
    /// JSON preserves their inline ids and content until the page's ordinary send builds ACP blocks.
    public var promptAttachments: [JSONValue]?
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
    /// The model a new chat starts on; nil keeps the harness or app default.
    public var model: String?
    /// The permission mode a new Cloud chat starts in (the person's pick in the composer before its
    /// first send); nil: the machine's own start mode. Only the caller's own Cloud VM applies it.
    public var mode: String?
    /// The effort a new chat starts on with ``model`` (a Cloud start's picker); nil keeps the default.
    public var effort: String?
    /// The requested destination for a new chat. The native handler consumes this before the
    /// page opens; retaining it in the seed keeps a destination-bearing seed from being treated
    /// as a folder-only New Tab replacement.
    public var host: String?
    /// A chat that opened without its folder: the page explains it and offers Choose Folder.
    public var folderNeeded: AgentPaneFolderNeeded?
    /// The device-wide chat (its index key, `harness:id`) whose past turns a new chat shows
    /// read-only until it has a session (cx-khns1); an adopted chat shows them while its folder's
    /// trust question holds the replay. Kept across page reloads.
    public var pastChat: String?
    /// The page opens on its Harnesses page (Integrate a Harness…, cx-uj5g8). Handed out once.
    public var showsHarnesses: Bool
    /// The page picks Cloud for its new chat, as the Where menu's Cloud row does (New Cloud Chat,
    /// `palette.newCloudChat`; handshake `pickCloud`). Handed out once.
    public var picksCloud: Bool
    /// The one-time token of the page that asked for this New Cloud Chat (`/side --on cloud`,
    /// `/cd --on cloud`; webviews commandPlace.ts), for the new page to find what it handed over.
    /// Handed out once, with ``picksCloud``.
    public var cloudStartHandoff: String?
    /// The Auto Cloud start whose arrival line belongs to this seeded chat.
    public var autoCloudStartKey: String?
    /// A Sandboxed send that already ended, shown by this new page as its own (a Run notification's
    /// click, ``AgentPaneSandboxRuns``).
    public var sandboxResult: SandboxResult?
    /// The `revealTurn` value the new page opens scrolled to (``AgentPaneModel/pendingRevealTurn``):
    /// the chats page's match in what was said. Handed out once.
    public var revealTurn: String?

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

    public init(cwd: String? = nil, draft: String? = nil, prompt: String? = nil, promptAttachments: [JSONValue]? = nil,
                promptBy: PromptBy = .automation,
                adopt: AgentPaneAdopt? = nil, surface: AgentPaneSurface? = nil, harness: String? = nil, model: String? = nil,
                mode: String? = nil, host: String? = nil,
                folderNeeded: AgentPaneFolderNeeded? = nil, pastChat: String? = nil, showsHarnesses: Bool = false,
                picksCloud: Bool = false, revealTurn: String? = nil) {
        self.revealTurn = revealTurn
        self.promptBy = promptBy
        self.showsHarnesses = showsHarnesses
        self.picksCloud = picksCloud
        self.folderNeeded = folderNeeded
        self.pastChat = pastChat
        self.cwd = cwd
        self.draft = draft
        self.prompt = prompt
        self.promptAttachments = promptAttachments
        self.adopt = adopt
        self.surface = surface
        self.harness = harness
        self.model = model
        self.mode = mode
        self.host = host
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
    /// This new page is a Mac tab's own again after the Cloud chat it showed in place went: it says so
    /// (``AgentPaneView/showCloudChatEnded(machine:promptBack:)``, cmux#55066), naming the machine.
    public var cloudChatEnded: (machine: String?, promptBack: Bool)?
    /// Runs once, when ``take()`` hands the page the seed's draft (not when the source is made: a host
    /// that fails before its handshake never takes it).
    public var onDraftTaken: (() -> Void)?

    /// The draft a hand-off gives later (``handingOffDraft(_:now:)``): ``take()`` waits for it.
    private var lateDraft: AgentPaneLateDraft?
    /// That hand-off, kept after ``take()`` read it (``draftMayBeTaken()``).
    private var handOff: AgentPaneLateDraft?
    /// Takes the text the sending tab holds at the hand-off (`text`) when the page was handed other text
    /// before it (`replaces`, ``draftMayBeTaken()``): whoever shows the page puts it in the page's composer.
    public var addDraft: (@MainActor (_ text: String, _ replaces: String) -> Void)?

    /// A seed whose draft is known only at a hand-off still to come: a Cloud start's chat, whose sending
    /// tab's composer stays open (Leo, 2026-11-09: "I can't click into the composer at all to, like
    /// potentially type other stuff while it's doing that initial load situation") until the App closes
    /// that tab, after the chat's tab is made and its folder trusted. The page's ``take()`` waits for the
    /// hand-off however long that takes (unless ``draftMayBeTaken()`` let it take the text early, and
    /// the hand-off then adds what was typed since), so nothing typed meanwhile is snapshotted early and dropped:
    /// the start hands off on every way out (``CloudStartChat`` `openUploaded` gives in a `defer`).
    /// ``peek()`` never waits. `give(true)` hands off the sending tab's text as `now` reads it then;
    /// `give(false)` (the start failed) hands off none. The first call counts.
    public static func handingOffDraft(_ seed: AgentPaneSeed, now: @escaping @MainActor () -> String?)
        -> (source: AgentPaneSeedSource, give: @MainActor (_ handedOff: Bool) -> Void) {
        let source = AgentPaneSeedSource(seed), handOff = AgentPaneLateDraft(now: now)
        (source.lateDraft, source.handOff) = (handOff, handOff)
        return (source, { if let late = handOff.give($0) { source.addDraft?(late.text, late.replaces) } })
    }

    /// The page may take the hand-off's text as it is typed when it asks, without waiting for the hand-off
    /// (``handingOffDraft(_:now:)``). For a start that waits for this page to draw before it hands off
    /// (``AgentPaneDrawFirst``): a page draws only once its handshake is answered, and the handshake takes the
    /// seed, so a seed that waited for the hand-off held the page, and the start's wait for it, to the wait's
    /// bound on every start. What is typed between the page's take and the hand-off is not lost: the hand-off
    /// gives it to ``addDraft``. Nothing changes for a seed with no hand-off, or one already handed off.
    public func draftMayBeTaken() { handOff?.open() }

    public init(limit: Duration = .seconds(1), _ read: @escaping @MainActor @Sendable () async -> AgentPaneSeed?) {
        self.read = read
        self.limit = limit
    }

    /// The seed holds a folder and nothing else (a new workspace's first New Tab page): a page
    /// that takes its folder from its New Tab context can stand in for it.
    public var holdsOnlyFolder: Bool {
        guard read == nil, sandboxResult == nil else { return false }
        guard let value else { return true }
        return value.draft == nil && value.prompt == nil && (value.promptAttachments?.isEmpty ?? true)
            && value.adopt == nil && value.surface == nil
            && value.harness == nil && value.model == nil && value.mode == nil && value.effort == nil && value.host == nil && value.folderNeeded == nil && value.pastChat == nil && !value.showsHarnesses
            && !value.picksCloud && value.cloudStartHandoff == nil
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

    /// Where the page opens scrolled to (``AgentPaneSeed/revealTurn``), when the seed is already known.
    public var revealTurn: String? { read == nil ? value?.revealTurn : nil }
    /// The seed's folder when it is already known (no read from another tab still to come).
    public var knownCwd: String? { read == nil ? value?.cwd : nil }
    /// A read from another tab is still to come: the seed's folder is not known yet.
    public var pending: Bool { read != nil }

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
        if let late = lateDraft {
            lateDraft = nil
            if let draft = await late.value(), !draft.isEmpty { value?.draft = draft }
        }
        let seed = value
        if seed?.draft != nil, let taken = onDraftTaken {
            onDraftTaken = nil
            taken()
        }
        value?.draft = nil
        value?.prompt = nil
        value?.promptAttachments = nil
        value?.showsHarnesses = false
        value?.picksCloud = false
        value?.cloudStartHandoff = nil
        value?.autoCloudStartKey = nil
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

extension AgentPaneSeed {
    /// New Cloud Chat's own seed (`palette.newCloudChat`): picks Cloud, carrying `handoff`
    /// (``cloudStartHandoff``).
    public static func picksCloud(handoff: String?) -> AgentPaneSeed {
        var seed = AgentPaneSeed(picksCloud: true)
        seed.cloudStartHandoff = handoff
        return seed
    }
}

extension AgentPaneSeedSource {
    /// New Cloud Chat: what New Agent Chat's tab inherits (`inherited`), with its page picking Cloud.
    /// `handoff`: the asking page's one-time token (``AgentPaneSeed/cloudStartHandoff``).
    public static func picksCloud(after inherited: AgentPaneSeedSource?, handoff: String? = nil) -> AgentPaneSeedSource {
        AgentPaneSeedSource {
            var seed = await inherited?.peek() ?? AgentPaneSeed()
            seed.picksCloud = true
            seed.cloudStartHandoff = handoff
            return seed
        }
    }
}

/// The sending tab's text, given later to whoever waits for it (``AgentPaneSeedSource/handingOffDraft(_:now:)``):
/// at the hand-off, or as it is typed when asked once ``open()`` allowed that.
@MainActor
final class AgentPaneLateDraft {
    private let now: @MainActor () -> String?
    /// The hand-off's text, fixed by ``give(_:)``; `.some(nil)` is a hand-off of none.
    private var given: String??
    /// An ask is answered with the text as it is typed then, before the hand-off.
    private var isOpen = false
    /// What an ask was answered with before the hand-off; nil while none was.
    private var early: String??
    private var waiting: [CheckedContinuation<String?, Never>] = []

    init(now: @escaping @MainActor () -> String?) { self.now = now }

    /// Asks no longer wait for the hand-off: one that waits is answered now, with the text as typed now.
    func open() {
        guard given == nil, !isOpen else { return }
        isOpen = true
        guard !waiting.isEmpty else { return }
        let text = now()
        early = .some(text)
        resume(text)
    }

    /// The hand-off: the text as typed now, or none (`handedOff` false: the start failed). The first call
    /// counts. When an ask was answered early with other text, returns the text now and the text it replaces,
    /// for the page to take.
    func give(_ handedOff: Bool) -> (text: String, replaces: String)? {
        guard given == nil else { return nil }
        let text = handedOff ? now() : nil
        given = .some(text)
        resume(text)
        guard handedOff, let early, (early ?? "") != (text ?? "") else { return nil }
        return (text ?? "", early ?? "")
    }

    func value() async -> String? {
        if let given { return given }
        if isOpen {
            let text = now()
            early = .some(text)
            return text
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func resume(_ text: String?) {
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume(returning: text) }
    }
}
