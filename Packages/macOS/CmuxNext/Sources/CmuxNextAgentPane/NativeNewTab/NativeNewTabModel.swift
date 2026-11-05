public import Observation

/// The native New Tab page's state: the typed text, the selected kind and the dropdown's
/// highlighted row (``NativeNewTabView`` draws it).
///
/// The rows are computed from the page's snapshot on each change, never stored, so they
/// cannot go stale. Construct one per page with the page and an action bundle:
///
/// ```swift
/// let model = NativeNewTabModel(page: page, actions: NativeNewTabActions(submit: { text, kind, search in … }))
/// ```
@MainActor @Observable
public final class NativeNewTabModel {
    /// The page's context: its omnibar lists (open tabs, workspaces, pages, palette actions).
    public private(set) var page: AgentPaneNewTab
    /// The field's text.
    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            highlighted = nil
            if !text.isEmpty { loadPaletteActions() }
        }
    }
    /// The Terminal | Browser | Agent switch.
    public var kind: AgentPaneTabKind
    /// The highlighted row's index in ``rows``; nil is the first row (Return's default).
    public var highlighted: Int?
    @ObservationIgnored private var actions: NativeNewTabActions
    @ObservationIgnored private let ranker: NativeNewTabRanker
    /// Asks for the palette's actions once, at the first keystroke or ``loadPaletteActions()``; they come later
    /// (the host reads them as budgeted background work, ``AgentPaneNewTabActions``), never in the keystroke's turn.
    /// `(wanted, deliver)`: `wanted` says whether the page still waits (false once it is gone), asked when the read starts.
    public typealias PaletteActionsRequest = @MainActor (_ wanted: @escaping @MainActor () -> Bool,
                                                         _ deliver: @escaping @MainActor ([AgentPaneOmnibar.Action]) -> Void) -> Void
    @ObservationIgnored private var paletteActions: PaletteActionsRequest?
    /// Which ask an answer belongs to: an adoption (a new tab's context) drops an earlier page's answer.
    @ObservationIgnored private var paletteAsk = 0

    /// Creates the model.
    /// - Parameters:
    ///   - page: The page's context, as the web page gets it.
    ///   - actions: What the page asks its host to do.
    ///   - ranker: Picks the dropdown's rows.
    ///   - paletteActions: Asks for the Commands palette's actions, when `page` was built without them so the
    ///     page shows first; nil when `page.omnibar.actions` already holds them.
    public init(page: AgentPaneNewTab, actions: NativeNewTabActions, ranker: NativeNewTabRanker = NativeNewTabRanker(),
                paletteActions: PaletteActionsRequest? = nil) {
        self.page = page
        self.kind = page.kind
        self.actions = actions
        self.ranker = ranker
        self.paletteActions = paletteActions
    }

    /// Asks for the dropdown's palette actions if they are not there yet (the host calls it on the frame after the
    /// page shows; the first keystroke calls it when that frame has not come). The rows take them when they come.
    public func loadPaletteActions() {
        guard let ask = paletteActions else { return }
        paletteActions = nil
        let asked = paletteAsk
        ask({ [weak self] in self.map { asked == $0.paletteAsk } ?? false }, { [weak self] actions in
            guard let self, asked == paletteAsk else { return }
            page.omnibar.actions = actions
        })
    }

    /// The dropdown's rows for the current text and kind.
    public var rows: [NativeNewTabRow] { ranker.rows(for: text, kind: kind, omnibar: page.omnibar) }

    /// The row Return takes.
    public var selectedIndex: Int? {
        let count = rows.count
        guard count > 0 else { return nil }
        return min(highlighted ?? 0, count - 1)
    }

    /// Cmd-T adopted this prepared page (the New Tab spare): it takes the new tab's context and
    /// requests, starts empty, and lists the palette's actions from `paletteActions` when asked.
    /// - Parameters:
    ///   - page: The new tab's context, built without the palette's actions.
    ///   - actions: What the page asks its host to do, for the tab it now is.
    ///   - paletteActions: Asks for the Commands palette's actions, once (``loadPaletteActions()``).
    public func adopt(page: AgentPaneNewTab, actions: NativeNewTabActions, paletteActions: PaletteActionsRequest?) {
        paletteAsk &+= 1
        self.page = page
        self.actions = actions
        self.paletteActions = paletteActions
        kind = page.kind
        text = ""
        highlighted = nil
    }

    /// The open tabs and workspaces changed while the page shows; the typed text stays.
    public func update(_ page: AgentPaneNewTab) { self.page = page }

    /// Down (`1`) or Up (`-1`): moves the highlight, wrapping at the ends.
    public func move(_ step: Int) {
        let count = rows.count
        guard count > 0 else { return }
        highlighted = ((selectedIndex ?? 0) + step + count) % count
    }

    /// Return: the highlighted row, or for an empty field the selected kind as it is (the open
    /// tabs listed under an empty field run only once Up or Down highlights one).
    public func commit() {
        if text.isEmpty, highlighted == nil { return actions.submit("", kind, false) }
        if let index = selectedIndex { return activate(rows[index]) }
        actions.submit("", kind, false)
    }

    /// Runs `row`, as Return or a click on it does.
    public func activate(_ row: NativeNewTabRow) {
        switch row {
        case .ask(let text): actions.submit(text, .agent, false)
        case .run(let text): actions.submit(text, .terminal, false)
        case .open(let text): actions.submit(text, .browser, false)
        case .tab(let tab): actions.jump(.tab, tab.id)
        case .workspace(let workspace): actions.jump(.workspace, workspace.id)
        case .page(let page): actions.submit(page.url, .browser, false)
        case .action(let action): actions.action(action.id)
        }
    }
}
