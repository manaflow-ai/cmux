#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxHomeCore
import CmuxHomeRender
import CmuxAgentQuestion
#if DEBUG
public import MessagesLabHome
#endif
public import CmuxNextDesign

/// DEBUG ONLY. A fixture for screenshots and dogfood: the real
/// `HomeNativeTranscriptView` (MessagesLab's code) over a
/// `HomeStore` over CmuxHomeCore's mock owner, showing its first (chief)
/// conversation. Compiled out of Release.
@MainActor
public final class HomeNativeFixture {
    public let container = NSView()
    /// The fixture tab's title.
    public static var title: String { HomeStrings.conversations }
    /// No latency; the Chief types for 1.5 s before it answers (the typing
    /// indicator shows, as in MessagesLab's script).
    private let source = MockHomeSource(options: .init(chiefHistory: 300, latency: .zero, replyDelay: .milliseconds(1500)))
    private let store: HomeStore
    private var view: HomeNativeTranscriptView?
    /// The shown conversation and its Chief (set once the view shows).
    private var shown: (conversation: ConversationID, chief: ParticipantID)?
    /// The Chief's streamed turn (`debugStream`) and its last draft seq.
    private var streamTurn: IdempotencyKey?
    private var streamSeq: UInt64 = 0
    /// The Chief reply key of the last `debugAgentMessages` run (its fold's anchor), and whether it was the notes run.
    private var lastAgentRun: (turn: IdempotencyKey, notes: Bool)?
    /// When the last `debugAgentMessages` run started (its steps keep their times as it grows).
    private var agentRunStart = Date()
    private var approvalDecider: HomeFixtureApprovalDecider?
    // task-owner: one fixture post; cancelled when the fixture closes or is replaced.
    private var approvalPost: Task<Void, Never>?
    // task-owner: kept and cancelled in `close()`
    private var loading: Task<Void, Never>?

    /// With `attachments`, the conversation also gets a photo, a video and a
    /// PDF from me (prepared and sent through the store like a drop).
    private let attachments: Bool
    /// The app's made-ahead file picker for the fixture's "+"; nil opens none.
    private let openPanel: MadeAheadOpenPanel?

    #if DEBUG
    /// DEBUG Agent Messages Playground: the header style, folds open, and the team chat (nil: not a playground).
    private var playground: (style: HomeAgentFoldStyle, expanded: Bool, team: Bool)?
    /// The playground's click on an agent's pill (the agent's id and its row's message id).
    var onPill: (@MainActor @Sendable (String, String) -> Void)?

    /// The Agent Messages Playground's fixture: it shows `playground`'s header style, folds and chat, with the
    /// playground's run, once it loads (``debugPlayground(style:expanded:team:)`` changes them later).
    public convenience init(playground: (style: HomeAgentFoldStyle, expanded: Bool, team: Bool)) {
        self.init()
        self.playground = playground
    }
    #endif

    public init(attachments: Bool = false, openPanel: MadeAheadOpenPanel? = nil) {
        self.attachments = attachments
        self.openPanel = openPanel
        store = HomeStore(source: source)
        store.start()
        loading = Task { [weak self] in await self?.load() }
    }

    /// Stops the store and the binding (the fixture tab closed).
    public func close() {
        loading?.cancel()
        approvalPost?.cancel()
        view?.stop()
        store.stop()
    }

    private func load() async {
        let chief = await source.chief.id
        guard let inbox = try? await source.inbox(), !Task.isCancelled,
              let id = (inbox.conversations.first { $0.participants.contains { $0.id == chief } && $0.participants.count == 2 }
                  ?? inbox.conversations.first)?.id else { return }
        await show(id, chief: chief, me: inbox.me.id)
        if attachments { await addAttachments(in: id) }
        #if DEBUG
        if let playground {
            view?.transcript.debugSetAgentFoldStyle(playground.style, onPill: onPill)
            _ = postAgentRun(Self.agentPlayground, notes: false, team: playground.team, step: 0, expanded: playground.expanded)
        }
        #endif
    }

    /// Shows conversation `id` in the container, in place of the one shown.
    private func show(_ id: ConversationID, chief: ParticipantID, me: ParticipantID) async {
        view?.stop()
        view?.removeFromSuperview()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me, openPanel: openPanel)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        self.view = view
        shown = (id, chief)
        await view.binding.opened()
    }

    /// Shows the mock's team chat (the Chief and two teammates: the Chief's avatar and name draw there),
    /// or with `team` false the Chief's own chat; nil when the mock has none.
    private func showChat(team: Bool) async -> (conversation: ConversationID, chief: ParticipantID)? {
        guard let shown, let inbox = try? await source.inbox(),
              let chat = inbox.conversations.first(where: { conversation in
                  conversation.participants.contains { $0.id == shown.chief } && (conversation.participants.count > 2) == team
              })
        else { return nil }
        if chat.id != shown.conversation { await show(chat.id, chief: shown.chief, me: inbox.me.id) }
        return self.shown
    }

    /// True when `view` is this fixture's transcript.
    public func shows(_ view: HomeNativeTranscriptView) -> Bool { self.view === view }

    /// Streams `text` as the Chief's running reply, the whole reply so far (an owner's fresh draft item);
    /// `done` ends the turn and posts `text` as the Chief's message. False before the conversation shows.
    public func debugStream(_ text: String, done: Bool) -> Bool {
        guard let shown else { return false }
        let turn = streamTurn ?? .make()
        streamTurn = done ? nil : turn
        streamSeq += 1
        let update = HomeDraftUpdate(conversation: shown.conversation, participant: shown.chief, turn: turn, segment: 0,
                                     seq: streamSeq, isTalk: true, text: text, fresh: true, done: done)
        let source = self.source
        // task-owner: one owner event, ends when the mock source has published it
        Task {
            await source.streamDraft(update)
            if done { await source.receive(text, from: shown.chief, in: shown.conversation) }
        }
        return true
    }

    /// Posts one mock permission through the real Home store and renderer. It can only use
    /// this fixture's mock decider; a socket call cannot send a permission response.
    /// `result` is what a later native pointer click receives: answered, refused or expired.
    public func debugApproval(result: String) -> Bool {
        guard let shown, let decision = HomeFixtureApprovalDecider.result(result) else { return false }
        approvalPost?.cancel()
        let decider = HomeFixtureApprovalDecider(decision)
        approvalDecider = decider
        view?.approvals = decider
        // This isolated fixture's decider only updates mock state, never acpmux.
        view?.isPersonApprovalEvent = { _ in true }
        let permission = "fixture-" + UUID().uuidString
        let snapshot = #"{"toolCall":{"title":"Bash","rawInput":{"command":"printf 'Hello from the subagent'"}},"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"no","kind":"reject_once"}]}"#
        let question = AgentQuestion(id: permission,
                                     source: .init(harness: .chief, session: "local/fixture-subagent", permission: permission),
                                     items: [.init(id: "approval:" + String(repeating: "a", count: 64), prompt: "a1: Bash",
                                                   options: [.init(id: "allow", label: "Allow once", preview: .init(text: snapshot)),
                                                             .init(id: "deny", label: "Deny")], allowsOther: false)])
        let source = self.source
        approvalPost = Task {
            await source.setOwner(.local, in: shown.conversation)
            guard !Task.isCancelled else { return }
            await source.post([.question(question)], from: shown.chief, in: shown.conversation, key: IdempotencyKey(permission))
        }
        return true
    }

    /// The mock decider's actual calls, for a real-pointer capture's oracle. Reading sends nothing.
    public var debugApprovalAttempts: [Bool] { approvalDecider?.attempts ?? [] }

    /// Foundation-compatible wire data, confined to this mock fixture. Reading sends nothing.
    public func debugApprovalState() -> [String: Any] {
        guard let view, let window = view.window else { return ["error": "no mock Home fixture is shown"] }
        let cards: [[String: Any]] = view.debugApprovalCards().map { card in
            ["id": card.id, "text": card.text, "pending": card.pending, "busy": card.busy, "ended": card.ended,
             "allow": HomeNativeTranscriptView.debugBox(card.allow), "deny": HomeNativeTranscriptView.debugBox(card.deny)]
        }
        return ["ok": !cards.isEmpty, "mock": true, "cards": cards,
                "attempts": debugApprovalAttempts.map { $0 ? "allow" : "deny" },
                "windowHeight": Double(window.frame.height), "scale": Double(window.backingScaleFactor)]
    }

    /// The mock's people `debug.home.drive` `presence` shows by default (made-up fixture people).
    public static let presencePeople = ["user_austin", "user_aziz", "user_leo"]

    /// Shows `people` (participant ids) as having the conversation open, as the owner's presence
    /// frame, and `typing` (one of them) typing; an empty list is nobody. False before the
    /// conversation shows.
    public func debugPresence(_ people: [String], typing: String?) -> Bool {
        guard let shown else { return false }
        let source = self.source
        // task-owner: one owner event each, ends when the mock source has published them
        let conversation = shown.conversation, viewing = Set(people.map { ParticipantID($0) })
        Task { () async -> Void in
            await source.showPresence(viewing, in: conversation)
            if let typing { await source.showTyping(ParticipantID(typing), in: conversation, on: true) }
        }
        return true
    }

    /// Holds the fixture's activity state for matching light/dark captures.
    /// No agent runs and no timer is installed; closing the fixture stops its store.
    public func debugTyping(_ on: Bool) -> Bool {
        guard let shown else { return false }
        let source = self.source
        // task-owner: one mock event, finishes after it is published
        Task { await source.typing(shown.chief, in: shown.conversation, on: on) }
        return true
    }

    /// Shows the Chief working, as a running turn's owner does: its typing bubble and the status line
    /// above it, made of each of `steps` in turn ("Reading", then "Starting agents"), the last begun
    /// `elapsed` seconds ago. False before the conversation shows.
    public func debugLive(_ steps: [String], elapsed: TimeInterval) -> Bool {
        guard let shown, !steps.isEmpty else { return false }
        let source = self.source
        let run = "debug-live-\(UUID().uuidString)"
        let start = Date().addingTimeInterval(-elapsed)
        // task-owner: one mock event per step, ends when the mock source has published them
        Task {
            await source.typing(shown.chief, in: shown.conversation, on: true)
            for (index, line) in steps.enumerated() {
                let since = start.addingTimeInterval(Double(index - steps.count + 1))
                let frame = HomeLiveActivityFrame(conversation: shown.conversation, author: shown.chief, run: run,
                                                  activity: HomeLiveActivity(line: line, since: since))
                await source.streamLive(.activity(frame))
            }
        }
        return true
    }

    /// Shows the Chief's messages to its agents and their reports as a real run brings them: my
    /// question, the Chief's reply, then one run with five messages to agents and one report, which
    /// Home folds into one row under the reply (a click expands it). False before the conversation shows.
    /// With `notes`, the run is instead five agents that stopped with no report (their session
    /// Disconnected, the Chief producer's note) and one real report.
    /// With `open`, nothing is posted: the agents row of the last such run (its stopped agents are in it
    /// too) opens or closes, as a click on it does.
    /// With `group`, the run goes to the mock's group with the Chief and two teammates (shown first).
    /// With `pill`, nothing is posted: agent `pill`'s chat opens in the agent pane, as a click on its pill does;
    /// with `say` too, the person sends that agent `say` from the pane's composer.
    /// With `step` N, the run brings only its first N messages: step 1 posts the question, the reply and
    /// one message; each next step adds one, as a live run does (0: all at once).
    public func debugAgentMessages(notes: Bool = false, open: Bool = false, group: Bool = false, step: Int = 0, pill: String? = nil,
                                   say: String? = nil) -> Bool {
        guard let shown else { return false }
        if let pill {
            guard let view else { return false }
            view.debugOpenAgent(pill)
            if let say { return view.debugSendToAgent(say) }
            return true
        }
        if open {
            guard let last = lastAgentRun else { return false }
            let group = HomeAgentMessageRow.groupID(author: shown.chief, anchor: last.turn)
            store.toggleAgentMessages(group, in: shown.conversation)
            return true
        }
        return postAgentRun(notes ? Self.agentNotes : Self.agentMessages, notes: notes, team: group ? true : nil, step: step)
    }

    /// Posts my question, the Chief's reply and a run of `all` (its first `step` messages; 0: all), in the
    /// team chat (`team` true), the Chief's own chat (false) or the one shown (nil); then with `expanded`
    /// opens or closes every fold of the run. False before the conversation shows.
    private func postAgentRun(_ all: [(peer: String, outgoing: Bool, text: String)], notes: Bool, team: Bool?, step: Int,
                              expanded: Bool? = nil) -> Bool {
        guard let shown else { return false }
        let source = self.source
        // Step 2 and on grow the last run; anything else starts a new one.
        let continuing = step > 1 ? lastAgentRun.flatMap { $0.notes == notes ? $0.turn : nil } : nil
        let turn = continuing ?? IdempotencyKey("debug-agent-messages-\(UUID().uuidString)")
        if continuing == nil { agentRunStart = Date() }
        lastAgentRun = (turn, notes)
        let start = agentRunStart
        let count = step > 0 ? min(step, all.count) : all.count
        // task-owner: a few mock events, ends when the mock source has published them
        Task { [weak self] in
            var target = shown
            if let team, continuing == nil, let chat = await self?.showChat(team: team) { target = chat }
            if continuing == nil {
                let me = await source.me.id
                _ = await source.post("What did you tell the agents just now?", from: me, in: target.conversation, key: .make())
                _ = await source.post("I sent five messages and got one report back.", from: target.chief, in: target.conversation, key: turn)
            }
            let messages = all.prefix(count).enumerated().map { index, m in
                HomeAgentRun.Message(id: "step-\(index)", sequence: UInt64(index + 1), revision: 1, peer: m.peer,
                                     outgoing: m.outgoing, text: m.text, date: start.addingTimeInterval(Double(index)))
            }
            // Each step is a newer revision of the run (one more message each).
            var revision: UInt64 = 0
            for _ in messages { revision += 1 }
            let run = HomeAgentRun(conversation: target.conversation, id: turn.rawValue, author: target.chief, turn: turn,
                                   answers: [], revision: revision, messages: messages)
            await source.streamLive(.run(HomeLiveRunChange(conversation: target.conversation, author: target.chief, run: turn.rawValue,
                                                           turn: turn, status: count < all.count ? "running" : "done", agentRun: run)))
            if let expanded { _ = self?.debugAgentFolds(expanded: expanded) }
        }
        return true
    }

    /// Opens or closes the agents row of the last run (its messages and its stopped agents), as a click
    /// on it does. False before a run.
    @discardableResult
    public func debugAgentFolds(expanded: Bool) -> Bool {
        guard let shown, let last = lastAgentRun else { return false }
        let group = HomeAgentMessageRow.groupID(author: shown.chief, anchor: last.turn)
        if store.isAgentMessagesExpanded(group, in: shown.conversation) != expanded {
            store.toggleAgentMessages(group, in: shown.conversation)
        }
        return true
    }

    #if DEBUG
    /// The Agent Messages Playground's state: draws the agent-message headers in `style` (and redraws the chat),
    /// shows the team chat or the Chief's own with the playground's run in it, and opens or closes its folds.
    /// Before the conversation shows, it is what the fixture shows first.
    public func debugPlayground(style: HomeAgentFoldStyle, expanded: Bool, team: Bool) {
        let was = playground
        playground = (style, expanded, team)
        guard shown != nil else { return }
        if was?.style != style { view?.transcript.debugSetAgentFoldStyle(style, onPill: onPill) }
        if was?.team != team || lastAgentRun == nil {
            _ = postAgentRun(Self.agentPlayground, notes: false, team: team, step: 0, expanded: expanded)
        } else if was?.expanded != expanded {
            debugAgentFolds(expanded: expanded)
        }
    }

    /// The playground's run: three agents told, one of them reporting back, and two that stopped with no report.
    private static var agentPlayground: [(peer: String, outgoing: Bool, text: String)] { HomeAgentPlaygroundAgent.run }
    #endif

    /// The notes fixture run: five status notes in the Chief producer's words, a real report.
    private static let agentNotes: [(peer: String, outgoing: Bool, text: String)] =
        ["a931", "a933", "a936", "a939", "a940"].map { ($0, false, "(stopped without a report: its session is Disconnected)") }
        + [("a891", false, "Fixed the stuck nightly feed: the feed and the installed NIGHTLY are on the same build. [run 41156389247](https://github.com/manaflow-ai/cmux/actions/runs/41156389247)")]

    /// The fixture run's messages (made-up agents and work, in the Chief's real wording).
    private static let agentMessages: [(peer: String, outgoing: Bool, text: String)] = [
        ("a938", true, "Buttons respond first click: test every button with one click, active and inactive window; fix the causes; add a CI guard."),
        ("a917", true, "Default picked: reserve one Mac mini's nightly slot so PR jobs stay off it, then land slice 2 with a plain push."),
        ("a934", true, "Add auto-archive: off by default, 3 days idle, in the Tidy Up dialog and Settings."),
        ("a929", true, "Hold the push until the fleet runs finish, then plain push to feat-cmux-next."),
        ("a888", true, "Check Text Size in the app and post light and dark shots.\n[Error: outcome: refused: agent was cancelled]"),
        ("a891", false, "Fixed the stuck nightly feed: the feed and the installed NIGHTLY are on the same build. [run 41156389247](https://github.com/manaflow-ai/cmux/actions/runs/41156389247)"),
    ]

    private func addAttachments(in id: ConversationID) async {
        guard let files = try? await HomeFixtureMedia.make(), !Task.isCancelled else { return }
        for file in files {
            guard let prepared = try? await store.prepareAttachment(fileURL: file, keepLocation: false) else { continue }
            try? await store.send(conversation: id, text: "", attachments: [prepared])
        }
    }
}
/// No acpmux connection or app-person proof exists in this mock. The production pointer gate
/// still has to accept the gesture before a successful decision can be recorded by Home.
@MainActor private final class HomeFixtureApprovalDecider: HomeApprovalDeciding {
    let decision: HomeApprovalDecision
    private(set) var attempts: [Bool] = []
    init(_ decision: HomeApprovalDecision) { self.decision = decision }
    static func result(_ value: String) -> HomeApprovalDecision? {
        switch value { case "answered": .answered; case "refused": .refused; case "expired": .expired; default: nil }
    }
    func decide(_ request: HomeApprovalRequest, allow: Bool,
                through gate: @escaping @Sendable (() -> Void) -> Bool) async -> HomeApprovalDecision {
        attempts.append(allow)
        if decision == .answered, !gate({}) { return .refused }
        return decision
    }
}
#endif
