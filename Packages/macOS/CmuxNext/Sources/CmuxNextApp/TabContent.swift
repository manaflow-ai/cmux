import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
import CmuxNextTerminal

/// What a pane shows for its selected tab.
enum TabContent {
    case terminal(TerminalEntry)
    case browser(BrowserEntry)
    /// An agent chat tab (a store conversation tab on an acpmux session), the React pane in a web view.
    case agent(AgentPaneView)
    /// An internal page tab (`LocalPageTab`): Settings, Debug Settings.
    case page(InternalPageView)
    /// A remote-terminal tab whose session is not attached (data-model.md 1.4).
    case placeholder(RemoteTerminalPlaceholderView)
    /// An agent chat tab whose session another Mac's acpmux runs ("This chat runs on <machine>").
    case notice(AgentTabElsewhereView)
    /// A conversation tab (`conversation-tabs-v1`): the native Home view
    /// of one conversation (plans/cmux-next/home.md 7).
    case conversation(HomeHostView)

    var view: NSView {
        switch self {
        case .terminal(let entry): entry.session.view
        case .browser(let entry): entry.chrome
        case .agent(let view): view
        case .page(let view): view
        case .placeholder(let view): view
        case .notice(let view): view
        case .conversation(let view): view
        }
    }

    /// Whether a page's document can take typing yet (the key router's
    /// type-ahead): an agent page or a React page tab.
    @MainActor var inputReadiness: PageInputReadiness? {
        switch self {
        case .agent(let view): view.inputReadiness
        case .page(let view): (view.content as? PageWebView)?.inputReadiness
        default: nil
        }
    }

    /// The kind a timed tab switch reports (`debug.tab_switch`).
    @MainActor var switchKind: String {
        switch self {
        case .terminal: "terminal"
        case .browser(let entry): entry.tab.engineKind == .cef ? "chromium" : "webkit"
        case .agent: "agent"
        case .page: "page"
        case .placeholder: "placeholder"
        case .notice: "notice"
        case .conversation: "conversation"
        }
    }

    /// A Ghostty terminal (it is ready on its first frame, not when shown).
    var isTerminal: Bool {
        if case .terminal = self { true } else { false }
    }

    /// The view that should become first responder when the pane is focused.
    var focusTarget: NSView {
        switch self {
        case .terminal(let entry): entry.session.surfaceView
        case .browser(let entry): entry.tab.contentView
        case .agent(let view): view.focusTarget
        case .page(let view): view.focusTarget
        case .placeholder(let view): view
        case .notice(let view): view
        case .conversation(let view): view.focusTarget
        }
    }
}

/// A live Ghostty surface attached to one daemon terminal.
final class TerminalEntry {
    /// Tab id plus the daemon generation and surface handle it attached to;
    /// a mismatch means the entry is stale (daemon restarted, tab moved).
    private(set) var validity: String
    let session: TerminalSession
    let io: DaemonTerminalIO
    /// Set while the terminal is a provisional split's (S3): the view attaches once the
    /// daemon's tab replaces the provisional one (``confirm(validity:target:themeKey:store:)``).
    private(set) var gate: TerminalTargetGate?
    /// The key of this terminal's own theme; a provisional split's moves to its daemon terminal at the confirm.
    private(set) var themeKey: TerminalThemeKey
    /// A provisional view waits for its tab's daemon surface (``TabContentCache/awaitConfirm(_:of:daemon:)``).
    var confirmation: Task<Void, Never>?
    weak var confirming: TabModel? // the tab record that task watches
    /// This surface's theme scope, under its pane's workspace scope.
    let themeScope = ThemeScope(level: .terminal)
    let themeBinding: TerminalThemeBinding
    /// Tab `dead` and connection changes for this view.
    private var watch: TerminalLinkWatch
    /// The TextBox composer under this terminal, made the first time a TextBox action runs on it.
    var textBox: TextBoxController?

    // cx-qxxu: released with its terminal, which Cmd-T's New Tab page can withdraw while its
    // action runs; a main-actor deinit's hop traps there (cx-t7hu).
    nonisolated deinit {}

    init(validity: String, session: TerminalSession, io: DaemonTerminalIO, themeKey: TerminalThemeKey, store: DaemonStore,
         surface: SurfaceID, gate: TerminalTargetGate? = nil) {
        self.validity = validity
        self.session = session
        self.io = io
        self.gate = gate
        self.themeKey = themeKey
        themeBinding = TerminalThemeBinding(scope: themeScope, session: session)
        themeScope.root(session.view)
        watch = TerminalLinkWatch(store: store, surface: surface, io: io, session: session)
    }

    /// The daemon's tab replaced the provisional one: the same view and session attach to it,
    /// and keys typed meanwhile reach it in order.
    func confirm(validity: String, target: TerminalAttachment.Target, themeKey: TerminalThemeKey, store: DaemonStore) {
        guard let gate else { return }
        self.validity = validity
        self.themeKey = themeKey
        self.gate = nil
        watch.stop()
        watch = TerminalLinkWatch(store: store, surface: target.surface, io: io, session: session)
        gate.resolve(target)
    }

    func close() {
        gate?.cancel()
        confirmation?.cancel()
        watch.stop()
        session.close()
        io.close()
        session.view.removeFromSuperview() // parked hidden in a pane until now
    }
}

/// A live browser page with its chrome.
final class BrowserEntry {
    let tab: any BrowserTab
    let chrome: BrowserChromeView
    /// Owns the chrome's (weak) Extensions menu handler.
    var extensionMenuHandler: (any ExtensionMenuHandling)?

    // No isolated-deinit hop inside an action's task-local scope (cx-t7hu).
    nonisolated deinit {
        BrowserPageRetirement(tab: tab, chrome: chrome).retire()
    }

    init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine(), history: (any BrowserHistoryStore)? = nil) {
        self.tab = tab
        chrome = BrowserChromeView(tab: tab, suggestionEngine: suggestionEngine)
        chrome.history = history
        // Shortcuts route through the action registry (browser* actions).
        chrome.handlesDefaultShortcuts = false
    }

    func close() {
        BrowserPageRetirement(tab: tab, chrome: chrome).retire()
    }
}
