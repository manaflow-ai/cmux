/// `chat.asks.open {sessionId, where?, turnId?, ask?}`: the person went to another chat's ask from Needs you (its
/// list, a row's answer or side question, the Needs your input pill, an expanded row's places).
///
/// `right` (no `where`, the default): a tab that shows that chat already beside this one (its pane
/// or right column, never another workspace) is shown and focused; else the chat opens on its right
/// as a link does (`layout.linkPlacement`, ``AgentPaneHeaderHooks/openRight``,
/// ``RightColumnPlacement``): a new split there, else a split below what is already on its right (a
/// plain split's terminal included), else a tab in the right column's lower pane, focused. Only when
/// that opens nothing, it goes where ``AgentSidePanes`` puts New side chat and `/btw`. The chat on
/// screen is never replaced: Needs you used to switch this pane to the other chat in place
/// (`chat.select`), and the person's own chat left its tab (Leo, 2026-10-21, his coordinator); nor
/// does it take a tab in this chat's pane (Leo, 2026-10-22: "just do more on the side? ... or just
/// do a split on the right").
///
/// The expanded row's other places, which the person picks by name (Leo, 2026-10-21: "MAYBE JUMP
/// TO THAT WORKSPACE... OR OPEN NEW WORKSPACE... OR OPEN ON RIGHT"): `workspace` switches to the tab
/// that shows the chat in whatever workspace or window (``AgentPaneHeaderHooks/jumpToSession``),
/// and opens it on the right as above when no tab shows it; `newWorkspace` opens it in a new
/// workspace (``AgentForkDestination/workspace``), else on the right.
///
/// What the pane that shows the chat does then (``AgentPaneAskThere``, Leo, 2026-10-20: "if you're
/// going to read anything, at least read from maybe the source, or like have an option to go to the
/// source, or like have an option to maybe even make a side chat to just ask like, okay, but what is
/// going on here?"): it scrolls to the asking turn, and starts Ask about this with the question.
/// This pane cannot do either for another chat, as the relay scopes both to the chat a pane shows
/// (``AcpmuxPaneMethods``); the pane that shows it can, through the reveal a `message=` link's
/// turn takes (``AgentPaneHeaderHooks/revealInSession``, ``AgentPaneHeaderHooks/openRightRevealing``).
/// The reply's `asked` says that pane got the question; without it the page says it did not.
///
/// Allowed for a chat on this pane's own acpmux on this Mac (``AgentPaneModel/pendingAsksSocket``,
/// whose chats Needs you lists, and a bare or `local/` id, ``AgentPanePendingAsks/localSession(_:)``):
/// the page's own client can already show any of them in place, so a tab of one grants nothing
/// more. Never the chat itself, a chat on another machine, or from a New Tab page; a refusal opens
/// nothing, and the page leaves the chat on screen as it is. Kept off ``AgentPaneModel``, whose
/// type is at its size limit.
enum AgentPaneAskOpen {
    @MainActor static func respond(_ session: String, at place: AgentPaneAskPlace = .right, there: AgentPaneAskThere = .init(),
                                   in model: AgentPaneModel) -> [String: Any] {
        guard let chat = model.sessionId, model.newTab == nil, let header = model.header,
              model.pendingAsksSocket != nil, let local = AgentPanePendingAsks.localSession(session),
              local != AgentPanePendingAsks.localSession(chat) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.asks.open")
        }
        let bare = String(local.dropFirst(AgentPanePendingAsks.localHost.count))
        let reveal = there.reveal(of: bare)
        let shown = { reveal.map { header.revealInSession?(bare, $0) ?? false } ?? false }
        switch place {
        case .workspace where header.jumpToSession(bare): return there.reply(revealed: shown())
        case .newWorkspace where header.openTab(bare, .workspace): return there.reply(revealed: false)
        case .right, .workspace, .newWorkspace: break
        }
        if header.showSession(bare) { return there.reply(revealed: shown()) }
        // A new tab on the right gets the reveal with its page's handshake; the side pane's tab,
        // only when nothing opened there, gets none, and the page says the question was not asked.
        if let reveal, let open = header.openRightRevealing {
            if open(bare, reveal) { return there.reply(revealed: true) }
        } else if header.openRight(bare) { return there.reply(revealed: false) }
        header.openSide(chat, bare)
        return there.reply(revealed: false)
    }
}

/// `chat.asks.open`'s `turnId` and `ask`: the asking turn the chat's pane scrolls to, and the
/// question it starts Ask about this with (``AgentPaneAskOpen``). Absent, the chat only opens.
public nonisolated struct AgentPaneAskThere: Equatable, Sendable {
    /// The longest question taken, as the page's side question box bounds what it sends.
    static let maximumAsk = 16_384
    public var turnId: String?
    public var ask: String?

    public init(turnId: String? = nil, ask: String? = nil) {
        (self.turnId, self.ask) = (turnId, ask)
    }

    /// Nil (refused) for a `turnId` or `ask` that is not a string, empty, or too long.
    init?(_ params: [String: Any]?) {
        if let value = params?["turnId"] {
            guard let turn = value as? String, !turn.isEmpty, turn.count <= 256 else { return nil }
            turnId = turn
        }
        if let value = params?["ask"] {
            guard let ask = value as? String, !ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ask.utf8.count <= Self.maximumAsk else { return nil }
            self.ask = ask
        }
    }

    /// The reveal the chat's page reads (webviews needsYou/askReveal.ts `revealedAsk`): an
    /// `ask:{sessionId, turnId?, question}` JSON value with a question, else the bare turn, else nil.
    func reveal(of session: String) -> String? {
        guard let ask else { return turnId }
        var value: [String: Any] = ["sessionId": session, "question": ask]
        if let turnId { value["turnId"] = turnId }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return turnId }
        return "ask:" + json
    }

    /// `{asked: true}` once a pane that shows the chat got the question.
    func reply(revealed: Bool) -> [String: Any] {
        ask != nil && revealed ? AgentPaneReply.success(["asked": true]) : AgentPaneReply.success()
    }
}

/// Where `chat.asks.open` opens the chat: its `where` (``AgentPaneAskOpen``).
public nonisolated enum AgentPaneAskPlace: String, Equatable, Sendable {
    case right
    case workspace
    case newWorkspace

    /// `where` absent is `right`; any value but the three names is nil (refused).
    init?(_ value: Any?) {
        guard let value else { self = .right; return }
        guard let name = value as? String, let place = Self(rawValue: name) else { return nil }
        self = place
    }
}
