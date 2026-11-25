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
/// (`computerUse.livePreview`) is the worker's. Where the person dragged a card, its size and
/// whether they hid it is the daemon's (computer_use_preview_place.rs): the router sends each
/// move, hide and show there (`remote-host-call computer_use.preview`), and every card comes back
/// with `place` and `hidden`. For a daemon that keeps none, the router still keeps the sessions the
/// person hid so a page that loads again does not bring their card back.
@MainActor
public final class ComputerUsePreviewRouter {
    /// The agent chat view showing acpmux session `chat`, if any.
    private let chat: @MainActor (_ chat: String) -> AgentPaneView?
    /// Sends the person's change to a session's card to the daemon (`computer_use.preview
    /// {session, x?, y?, size?, hidden?}`).
    private let place: @MainActor (_ session: String, _ update: [String: JSONValue]) -> Void
    /// Whether a terminal pane's card can be dragged, made full size and hidden to a chip
    /// (`labs.previewFeatures`, off by default): off, it is the top right card a click enlarges.
    private let controls: @MainActor () -> Bool
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
                terminal: @escaping @MainActor (String) -> (tab: String, host: TerminalHostView)?,
                place: @escaping @MainActor (_ session: String, _ update: [String: JSONValue]) -> Void = { _, _ in },
                controls: @escaping @MainActor () -> Bool = { false }) {
        self.chat = chat
        self.terminal = terminal
        self.place = place
        self.controls = controls
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
        // A daemon that keeps the place says `hidden` on every card (a hidden card shows as a chip);
        // for one that keeps none, a card the person hid shows none.
        let card: [String: JSONValue]? = if case .object(let card)? = line["card"], card["hidden"] != nil || !hidden.contains(session) { card } else { nil }
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
            switch action {
            case .open: break
            case .close: self?.hide(session)
            case .show: self?.unhide(session)
            case .place(let move): self?.place(session, Self.update(move))
            }
        }
    }

    /// The daemon's update for a move from the page.
    static func update(_ move: AgentPaneComputerUsePreview.Move) -> [String: JSONValue] {
        var update: [String: JSONValue] = [:]
        if let x = move.x { update["x"] = .number(x) }
        if let y = move.y { update["y"] = .number(y) }
        if let size = move.size { update["size"] = .string(size.rawValue) }
        return update
    }

    private func show(_ card: TerminalComputerUsePreview.Card?, tab: String, host: TerminalHostView) {
        let view: TerminalComputerUsePreview
        if let made = terminalCards[tab], host.computerUsePreview === made {
            view = made
        } else {
            guard card != nil else { return }
            view = TerminalComputerUsePreview()
            view.onClose = { [weak self] session in self?.hide(session) }
            view.onShow = { [weak self] session in self?.unhide(session) }
            view.onMove = { [weak self] session, move in
                self?.place(session, Self.update(.init(x: move.x, y: move.y, size: move.size.flatMap { .init(rawValue: $0.rawValue) })))
            }
            terminalCards[tab] = view
            host.computerUsePreview = view
        }
        view.movable = controls()
        view.show(card)
    }

    private func hide(_ session: String) {
        if hidden.count >= 64 { hidden.removeAll() }
        hidden.insert(session)
        place(session, ["hidden": .bool(true)])
    }

    /// The person brought `session`'s card back: the daemon sends its newest frame at once.
    private func unhide(_ session: String) {
        hidden.remove(session)
        place(session, ["hidden": .bool(false)])
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
        return AgentPaneComputerUsePreview(session: session, app: app, done: card["done"] == .bool(true), frame: frame, pointer: pointer,
                                           place: Self.place(card), hidden: card["hidden"] == .bool(true))
    }

    /// The card's `place {x, y, size}` as the daemon sends it; nil for none or a malformed one.
    static func place(_ card: [String: JSONValue]) -> AgentPaneComputerUsePreview.Place? {
        guard case .object(let place)? = card["place"], case .number(let x)? = place["x"], case .number(let y)? = place["y"] else { return nil }
        let size: AgentPaneComputerUsePreview.Size = if case .string(let raw)? = place["size"] { .init(rawValue: raw) ?? .small } else { .small }
        return .init(x: x, y: y, size: size)
    }

    /// The terminal pane's card of a preview line's `card`.
    static func terminalCard(_ card: [String: JSONValue]?) -> TerminalComputerUsePreview.Card? {
        guard let chat = chatCard(card) else { return nil }
        let place = chat.place.map { TerminalComputerUsePreview.Place(x: $0.x, y: $0.y, size: .init(rawValue: $0.size.rawValue) ?? .small) }
        return TerminalComputerUsePreview.Card(session: chat.session, app: chat.app, done: chat.done, frame: chat.frame ?? "",
                                               pointer: chat.pointer.map { CGPoint(x: $0.x, y: $0.y) }, clicks: Int(chat.pointer?.click ?? 0),
                                               place: place, hidden: chat.hidden)
    }
}
