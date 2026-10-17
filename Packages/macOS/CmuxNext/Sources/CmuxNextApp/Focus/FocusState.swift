import CmuxNextDesign


/// The focus of one window: the single owner of "what has the keyboard"
/// (plans/cmux-next/focus.md section 4). Client-local, never persisted,
/// never sent to the daemon. AppKit first responder, Ghostty surface focus,
/// WebKit/CEF page focus, `LayoutModel.focusedPane` and the registry
/// context are outputs of it (`FocusEffectApplier`).
///
/// The app's read view of `cmux-focus-core`'s state
/// (cmux-tui/crates/cmux-focus-core). The state itself, with the per
/// workspace memory and history, lives in the window's `FocusMachine`; the
/// rules, including what the state resolves to, run there. This view holds
/// only what the app reads, refreshed from each typed reply, plus the
/// topology the app last sent (kept equal to the machine's).
nonisolated struct FocusState: Hashable, Sendable {
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

    var windowKey = false
    var appActive = false
    /// The topology the window last sent, with the machine's own selection
    /// changes (`select` effects) applied: equal to the machine's topology.
    var topology = FocusTopology()
    var pane: String?
    var target: Target = .content
    var overlays: [Overlay] = []
    var expectation: Expectation?
    /// A tab drag is in flight (its restore point is the machine's).
    var isDragging = false
    /// Browser tabs in browser focus mode (from the machine's effects).
    var browserFocusMode: Set<String> = []
    /// Bumped by every user intent.
    var generation: UInt64 = 0
    /// The sidebar is hidden: it cannot be a focus target.
    var sidebarHidden = false
    /// The keyboard target, the top overlay first.
    var resolved: Resolved = .none
    /// The target below any overlay (what closing the overlays restores,
    /// and what the palette's commands act on).
    var underlying: Resolved = .none
    /// The registry context bits: the sidebar, other text fields, sheets and
    /// rename prompts clear them; the palette keeps the bits of what is below.
    var context = Context()
    /// The focused page is in browser focus mode.
    var isBrowserFocusModeActive = false

    /// What the settle observers act on: they run only when it changed.
    struct SettleKey: Hashable {
        var windowKey: Bool
        var appActive: Bool
        var workspace: String?
        var target: Target
        var resolved: Resolved
    }

    var settleKey: SettleKey {
        SettleKey(windowKey: windowKey, appActive: appActive, workspace: topology.workspace, target: target, resolved: resolved)
    }
}
