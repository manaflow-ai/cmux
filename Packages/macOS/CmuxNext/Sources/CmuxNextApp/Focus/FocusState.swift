import CmuxNextDesign


/// The focus of one window: the single owner of "what has the keyboard"
/// (plans/cmux-next/focus.md section 4). Client-local, never persisted,
/// never sent to the daemon. AppKit first responder, Ghostty surface focus,
/// WebKit/CEF page focus, `LayoutModel.focusedPane` and the registry
/// context are outputs of it (`FocusEffectApplier`).
nonisolated struct FocusState: Hashable, Sendable, Codable {
    /// What inside (or outside) the focused pane has the keyboard.
    enum Target: Hashable, Sendable, Codable {
        /// The focused pane's selected tab content (terminal or page).
        case content
        case addressBar
        case findBar
        /// The focused page's docked developer tools (a separate keyboard
        /// target inside the pane, like the address bar).
        case devTools
        /// The sidebar list. `keyboard` when it got there by keyboard
        /// (arrow navigation keeps it through workspace switches).
        case sidebar(keyboard: Bool)
        /// Sidebar search or inline rename field.
        case sidebarField
        /// Any other text field in the window.
        case textField
        case none

        /// The sidebar list or one of its fields.
        var isSidebar: Bool {
            switch self {
            case .sidebar, .sidebarField: true
            default: false
            }
        }

        var isPaneScoped: Bool {
            switch self {
            case .content, .addressBar, .findBar, .devTools: true
            default: false
            }
        }
    }

    /// Something that takes the keyboard above the window content.
    enum Overlay: String, Hashable, Sendable, Codable {
        case palette
        case sheet
        case rename
        case groupEditor
    }

    /// A focus that lands once its tab exists (a split, new tab, drop).
    struct Expectation: Hashable, Sendable, Codable {
        init(key: Key, target: Target, awayFrom: String? = nil, generation: UInt64) {
            self.key = key
            self.target = target
            self.awayFrom = awayFrom
            self.generation = generation
        }

        enum Key: Hashable, Sendable, Codable {
            case surface(String)
            case tab(String)
        }

        var key: Key
        var target: Target
        /// Lands only in a pane other than this one (a moved tab still
        /// sits in its source pane until the daemon moves it).
        var awayFrom: String?
        /// The user-intent generation that asked for it; a newer intent
        /// drops it (no focus steal after the user moved on).
        var generation: UInt64
    }

    /// Where focus returns when a drag is cancelled.
    struct DragRestore: Hashable, Sendable, Codable {
        var tabs: [String]
        var sourcePane: String
        var pane: String?
        var target: Target
        /// The focused pane's selected tab when the drag began (chrome
        /// targets belong to it).
        var tab: String?
        /// A keyboard, CLI or palette intent happened during the drag (mouse
        /// events during it belong to the drag): it wins over the restore.
        var overridden = false
    }

    /// The one keyboard target the state implies.
    enum Resolved: Hashable, Sendable {
        case terminal(pane: String, tab: String)
        case browserPage(pane: String, tab: String)
        case addressBar(pane: String, tab: String)
        case findBar(pane: String, tab: String)
        /// The page's docked DevTools has the keyboard.
        case devTools(pane: String, tab: String)
        /// An agent chat tab's page has the keyboard.
        case agentPage(pane: String, tab: String)
        /// An internal page tab (`LocalPageTab`) has the keyboard.
        case page(pane: String, tab: String)
        /// A conversation tab (Home) has the keyboard: its message box.
        case conversation(pane: String, tab: String)
        /// A focused pane with no content to type into (empty, loading).
        case emptyPane(pane: String)
        case sidebar
        case sidebarField
        case textField
        case overlay(Overlay)
        case none

        var pane: String? {
            switch self {
            case .terminal(let pane, _), .browserPage(let pane, _), .addressBar(let pane, _), .findBar(let pane, _),
                 .devTools(let pane, _), .agentPage(let pane, _), .page(let pane, _), .conversation(let pane, _): pane
            case .emptyPane(let pane): pane
            default: nil
            }
        }

        var tab: String? {
            switch self {
            case .terminal(_, let tab), .browserPage(_, let tab), .addressBar(_, let tab), .findBar(_, let tab),
                 .devTools(_, let tab), .agentPage(_, let tab), .page(_, let tab), .conversation(_, let tab): tab
            default: nil
            }
        }

        /// A text field has the keyboard: editing chords belong to it.
        var isTextInput: Bool {
            switch self {
            case .addressBar, .findBar, .sidebarField, .textField: true
            case .overlay(let overlay): overlay == .rename || overlay == .sheet
            default: false
            }
        }

        /// The docked DevTools has the keyboard: content chords are its own.
        var isDevTools: Bool {
            if case .devTools = self { return true }
            return false
        }

        /// Stable name for `debug.focus`.
        var kind: String {
            switch self {
            case .terminal: "terminal"
            case .browserPage: "browserPage"
            case .addressBar: "addressBar"
            case .findBar: "findBar"
            case .devTools: "devTools"
            case .agentPage: "agentPage"
            case .page: "page"
            case .conversation: "conversation"
            case .emptyPane: "emptyPane"
            case .sidebar: "sidebar"
            case .sidebarField: "sidebarField"
            case .textField: "textField"
            case .overlay(let overlay): "overlay:\(overlay.rawValue)"
            case .none: "none"
            }
        }
    }

    /// Registry context bits the focus implies.
    struct Context: Hashable, Sendable, Codable {
        var terminal = false
        var browser = false
        var agent = false
        /// A diff viewer tab (`diffViewerFocused`, its navigation actions).
        var diff = false
    }

    var windowKey = false
    var appActive = false
    var topology = FocusTopology()
    var pane: String?
    var target: Target = .content
    var overlays: [Overlay] = []
    /// Last focused pane per workspace (restored on switching back).
    var remembered: [String: String] = [:]
    /// Recently focused panes per workspace, newest first, from every
    /// source (click, keyboard, CLI, palette, app-driven landing). The
    /// successor of a closed pane and the tie-breaker of directional focus
    /// (focus.md section 4a). Closed panes are dropped when the workspace's
    /// topology arrives; in memory only.
    var history: [String: [String]] = [:]
    static let historyLimit = 64

    /// The shown workspace's focus history, newest first.
    var recentPanes: [String] {
        topology.workspace.flatMap { history[$0] } ?? []
    }
    var expectation: Expectation?
    var drag: DragRestore?
    /// Browser tabs in browser focus mode (all keys but tier 0 go to the page).
    var browserFocusMode: Set<String> = []
    /// Bumped by every user intent.
    var generation: UInt64 = 0
    /// The sidebar is hidden: it cannot be a focus target.
    var sidebarHidden = false
    /// `layout.closeFocus`: the successor rule when the focused pane closes
    /// (close-focus.md). The coordinator copies the setting in.
    var closeFocus: CloseFocusPolicy = .previousNeighbor

    var resolved: Resolved {
        if let top = overlays.last { return .overlay(top) }
        return underlying
    }

    /// The target below any overlay (what closing the overlays restores,
    /// and what the palette's commands act on).
    var underlying: Resolved {
        switch target {
        case .sidebar: return .sidebar
        case .sidebarField: return .sidebarField
        case .textField: return .textField
        case .none: return .none
        case .content, .addressBar, .findBar, .devTools:
            guard let pane, let model = topology.pane(pane) else { return .none }
            guard let tab = model.selectedTab else { return .emptyPane(pane: pane) }
            switch (tab.kind, target) {
            case (.browser, .addressBar): return .addressBar(pane: pane, tab: tab.id)
            case (.browser, .findBar): return .findBar(pane: pane, tab: tab.id)
            case (.browser, .devTools): return .devTools(pane: pane, tab: tab.id)
            case (.browser, _): return .browserPage(pane: pane, tab: tab.id)
            case (.terminal, _): return .terminal(pane: pane, tab: tab.id)
            case (.agent, _): return .agentPage(pane: pane, tab: tab.id)
            case (.page, _): return .page(pane: pane, tab: tab.id)
            case (.conversation, _): return .conversation(pane: pane, tab: tab.id)
            case (.other, _): return .emptyPane(pane: pane)
            }
        }
    }

    /// The sidebar, other text fields, sheets and rename prompts clear both
    /// bits, so content-scoped actions (Copy, Paste) cannot run while the
    /// user types there. Address bar and find bar keep `browserFocused`.
    /// The palette keeps the bits of what is below it: its commands act on
    /// the window's focused content.
    var context: Context {
        if let top = overlays.last, top != .palette { return Context() }
        switch underlying {
        case .terminal: return Context(terminal: true)
        case .browserPage, .addressBar, .findBar, .devTools: return Context(browser: true)
        case .agentPage: return Context(agent: true)
        case .page(_, let tab) where LocalPageTab.page(of: tab) == .diff: return Context(diff: true)
        default: return Context()
        }
    }

    /// The focused page is in browser focus mode.
    var isBrowserFocusModeActive: Bool {
        guard case .browserPage(_, let tab) = resolved else { return false }
        return browserFocusMode.contains(tab)
    }
}
