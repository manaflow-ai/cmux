public import AppKit
public import CmuxNextAgentPane
public import CmuxNextDaemon
public import CmuxNextTerminal

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

    public init(chat: @escaping @MainActor (String) -> AgentPaneView?,
                terminal: @escaping @MainActor (String) -> (tab: String, host: TerminalHostView)?) {
        self.chat = chat
        self.terminal = terminal
    }

    /// Follows `store`'s `computer-use-preview` events (pushed, never polled).
    public func follow(_ store: DaemonStore) {
        guard subscription == nil else { return }
        subscription = store.sideEvents.subscribe { [weak self] event in
            guard case .unknown(name: "computer-use-preview", let payload) = event else { return }
            self?.take(payload)
        }
    }

    func take(_ payload: JSONValue) {
        guard case .object(let line) = payload, case .string(let session)? = line["session"],
              case .object(let surface)? = line["surface"] else { return }
        let card: [String: JSONValue]? = if case .object(let card)? = line["card"], !hidden.contains(session) { card } else { nil }
        if case .string(let id)? = surface["chat"] {
            guard let view = chat(id) else { return }
            AgentPaneComputerUsePreview.show(Self.chatCard(card), on: view) { [weak self] session, action in
                if action == .close { self?.hide(session) }
            }
        } else if case .string(let id)? = surface["terminal"], let (tab, host) = terminal(id) {
            show(Self.terminalCard(card), tab: tab, host: host)
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
