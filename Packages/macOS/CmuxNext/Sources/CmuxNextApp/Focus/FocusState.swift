import CmuxNextDesign


/// The focus of one window: the single owner of "what has the keyboard"
/// (plans/cmux-next/focus.md section 4). Client-local, never persisted,
/// never sent to the daemon. AppKit first responder, Ghostty surface focus,
/// WebKit/CEF page focus, `LayoutModel.focusedPane` and the registry
/// context are outputs of it (`FocusEffectApplier`).
///
/// A value mirror of `cmux-focus-core`'s state (cmux-tui/crates/cmux-focus-core):
/// the rules, including what the state resolves to (`derived`), run there,
/// through `FocusReducer` over the app FFI. Its synthesized `Codable` shape
/// is the wire shape.
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
    enum Resolved: Hashable, Sendable, Codable {
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
    }

    /// What the state resolves to, computed by the Rust reducer on every
    /// reduction (`cmux-focus-core` `Derived`).
    struct Derived: Hashable, Sendable, Codable {
        /// The keyboard target, the top overlay first.
        var resolved: Resolved = .none
        /// The target below any overlay.
        var underlying: Resolved = .none
        var context = Context()
        var browserFocusModeActive = false
        /// The shown workspace's focus history, newest first.
        var recentPanes: [String] = []
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
    /// Filled by the reducer; the rest of the state never changes outside it.
    private(set) var derived = Derived()

    /// The shown workspace's focus history, newest first.
    var recentPanes: [String] { derived.recentPanes }

    var resolved: Resolved { derived.resolved }

    /// The target below any overlay (what closing the overlays restores,
    /// and what the palette's commands act on).
    var underlying: Resolved { derived.underlying }

    /// The registry context bits: the sidebar, other text fields, sheets and
    /// rename prompts clear them; the palette keeps the bits of what is below.
    var context: Context { derived.context }

    /// The focused page is in browser focus mode.
    var isBrowserFocusModeActive: Bool { derived.browserFocusModeActive }
}
