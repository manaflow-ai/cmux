public import AppKit
public import CmuxNextAgentPane
public import CmuxNextDaemon
public import CmuxNextTerminal
import os

private let logger = Logger(subsystem: "com.cmuxterm.next", category: "computer-use-preview")

/// Computer Use's live preview in the cmux surface its agent runs in: each `computer-use-preview`
/// event of the local daemon (the worker's preview hub, cmux-computer-use preview.rs, relayed by
/// the daemon with the agent's surface) goes to that agent chat's card
/// (``AgentPaneComputerUsePreview``) or that terminal pane's (``TerminalComputerUsePreview``).
///
/// What a card shows, when it runs, turns done or goes, and whether previews run at all
/// (`computerUse.livePreview`) is the worker's; this only finds the view, and keeps the sessions the
/// person hid so a page that loads again does not bring their card back.
@MainActor
public final class ComputerUsePreviewRouter {
    /// The agent chat view showing acpmux session `chat`, if any.
    private let chat: @MainActor (_ chat: String) -> AgentPaneView?
    /// The terminal view of the tab whose terminal is `terminal` (`CMUX_TUI_TERMINAL_ID`), with the
    /// tab's id, if it has a surface.
    private let terminal: @MainActor (_ terminal: String) -> (tab: String, host: TerminalHostView)?
    /// Sessions whose card the person hid (a few per launch).
    private var hidden: Set<String> = []
    /// The terminal cards made, by tab id.
    private var terminalCards: [String: TerminalComputerUsePreview] = [:]
    private var subscription: UInt64?
    /// The session each surface's card shows (`chat:<id>`, `terminal:<tab>`): a surface shows one
    /// card, so a line of another session that ended (its card done or gone) leaves it alone.
    private var shownSession: [String: String] = [:]
    /// Each chat's newest card, for a chat whose page is made later (a chat started in the
    /// background, a tab not shown yet): ``replayChats()`` gives it then.
    private var chatCards: [String: [String: JSONValue]] = [:]
    /// What the last line of each session did, so the log says each change once.
    private var outcomes: [String: String] = [:]

    public init(chat: @escaping @MainActor (String) -> AgentPaneView?,
                terminal: @escaping @MainActor (String) -> (tab: String, host: TerminalHostView)?) {
        self.chat = chat
        self.terminal = terminal
    }

    /// Follows `store`'s `computer-use-preview` events (pushed, never polled).
    public func follow(_ store: DaemonStore) {
        guard subscription == nil else { return }
        logger.notice("preview follows the local daemon's computer-use-preview events")
        subscription = store.sideEvents.subscribe { [weak self] event in
            guard case .unknown(name: "computer-use-preview", let payload) = event else { return }
            self?.take(payload)
        }
    }

    func take(_ payload: JSONValue) {
        guard case .object(let line) = payload, case .string(let session)? = line["session"],
              case .object(let surface)? = line["surface"] else { return }
        let card: [String: JSONValue]? = if case .object(let card)? = line["card"], !hidden.contains(session) { card } else { nil }
        let state = card == nil ? "none" : (card?["done"] == .bool(true) ? "done" : "running")
        if case .string(let id)? = surface["chat"] {
            guard applies(session, running: state == "running", to: "chat:\(id)") else { return }
            if let card {
                if chatCards.count >= 32, chatCards[id] == nil { chatCards.removeAll() }
                chatCards[id] = card
            } else {
                chatCards[id] = nil
            }
            guard let view = chat(id) else { return note(session, "\(state), no chat page yet") }
            showInChat(card, on: view)
            note(session, "\(state) in its chat")
        } else if case .string(let id)? = surface["terminal"] {
            guard let (tab, host) = terminal(id) else { return note(session, "\(state), no terminal view") }
            guard applies(session, running: state == "running", to: "terminal:\(tab)") else { return }
            show(Self.terminalCard(card), tab: tab, host: host)
            note(session, "\(state) in terminal tab \(tab)")
        }
    }

    /// Whether `session`'s line changes the card of surface `key`: a running card takes the surface
    /// (the agent acting now), any line of the session shown changes it, and a line of another
    /// session that is no longer running (done, gone) leaves the card shown alone.
    func applies(_ session: String, running: Bool, to key: String) -> Bool {
        let shown = shownSession[key]
        guard running || shown == nil || shown == session else { return false }
        if shownSession.count > 64 { shownSession.removeAll() }
        shownSession[key] = session
        return true
    }

    private func note(_ session: String, _ outcome: String) {
        guard outcomes[session] != outcome else { return }
        if outcomes.count > 64 { outcomes.removeAll() }
        outcomes[session] = outcome
        logger.notice("preview \(session, privacy: .public): \(outcome, privacy: .public)")
    }

    /// A chat's page was made or now shows another chat (``AgentTabStore/onTabSession``): the chats
    /// whose card came before their page get it now.
    public func replayChats() {
        for (id, card) in chatCards {
            guard let view = chat(id), view.model.computerUsePreview == nil else { continue }
            showInChat(card, on: view)
        }
    }

    private func showInChat(_ card: [String: JSONValue]?, on view: AgentPaneView) {
        AgentPaneComputerUsePreview.show(Self.chatCard(card), on: view) { [weak self] session, action in
            if action == .close { self?.hide(session) }
        }
    }

    private func show(_ card: TerminalComputerUsePreview.Card?, tab: String, host: TerminalHostView) {
        let view: TerminalComputerUsePreview
        if let made = terminalCards[tab], host.computerUsePreview === made {
            view = made
        } else {
            guard card != nil else { return }
            view = TerminalComputerUsePreview()
            view.onClose = { [weak self] session in self?.hide(session) }
            terminalCards[tab] = view
            host.computerUsePreview = view
        }
        view.show(card)
    }

    private func hide(_ session: String) {
        if hidden.count >= 64 { hidden.removeAll() }
        hidden.insert(session)
    }

    /// The agent chat's card of a preview line's `card`.
    static func chatCard(_ card: [String: JSONValue]?) -> AgentPaneComputerUsePreview? {
        guard let card, case .string(let session)? = card["session"], case .string(let frame)? = card["frame"] else { return nil }
        let app: String = if case .string(let app)? = card["app"] { app } else { "" }
        var pointer: AgentPaneComputerUsePreview.Pointer?
        if case .object(let p)? = card["pointer"], case .number(let x)? = p["x"], case .number(let y)? = p["y"] {
            let click: Double = if case .number(let c)? = p["click"] { c } else { 0 }
            let width: Double? = if case .number(let w)? = p["windowWidth"] { w } else { nil }
            pointer = .init(x: x, y: y, click: UInt64(max(0, click)), windowWidth: width)
        }
        return AgentPaneComputerUsePreview(session: session, app: app, done: card["done"] == .bool(true), frame: frame, pointer: pointer)
    }

    /// The terminal pane's card of a preview line's `card`.
    static func terminalCard(_ card: [String: JSONValue]?) -> TerminalComputerUsePreview.Card? {
        guard let chat = chatCard(card) else { return nil }
        return TerminalComputerUsePreview.Card(session: chat.session, app: chat.app, done: chat.done, frame: chat.frame ?? "",
                                               pointer: chat.pointer.map { CGPoint(x: $0.x, y: $0.y) }, clicks: Int(chat.pointer?.click ?? 0))
    }
}
