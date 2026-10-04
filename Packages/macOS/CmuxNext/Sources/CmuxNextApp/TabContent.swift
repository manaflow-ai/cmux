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
    /// An agent chat tab (`LocalAgentTab`), the React pane in a web view.
    case agent(AgentPaneView)
    /// An internal page tab (`LocalPageTab`): Settings, Debug Settings.
    case page(InternalPageView)
    /// A remote-terminal tab whose session is not attached (data-model.md 1.4).
    case placeholder(RemoteTerminalPlaceholderView)
    /// A conversation tab (`conversation-tabs-v1`): the native Home view
    /// of one conversation (plans/cmux-next/home.md 7).
    case conversation(HomeHostView)
    /// An app tab (`app-screens-v1`): the app's own page, the same view an
    /// app screen shows (`AppsService.tabView(for:)`).
    case app(AppTabView)

    var view: NSView {
        switch self {
        case .terminal(let entry): entry.session.view
        case .browser(let entry): entry.chrome
        case .agent(let view): view
        case .page(let view): view
        case .placeholder(let view): view
        case .conversation(let view): view
        case .app(let view): view
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

    /// A Ghostty terminal (it is ready on its first frame, not when shown).
    var isTerminal: Bool {
        if case .terminal = self { true } else { false }
    }

    /// The view that should become first responder when the pane is focused.
    var focusTarget: NSView {
        switch self {
        case .terminal(let entry): entry.session.surfaceView
        case .browser(let entry): entry.tab.contentView
        case .agent(let view): view.webView
        case .page(let view): view.focusTarget
        case .placeholder(let view): view
        case .conversation(let view): view.focusTarget
        case .app(let view): view.focusTarget
        }
    }
}

/// A live Ghostty surface attached to one daemon terminal.
final class TerminalEntry {
    /// Tab id plus the daemon generation and surface handle it attached to;
    /// a mismatch means the entry is stale (daemon restarted, tab moved).
    let validity: String
    let session: TerminalSession
    let io: DaemonTerminalIO
    /// The key of this terminal's own theme.
    let themeKey: TerminalThemeKey
    /// This surface's theme scope, under its pane's workspace scope.
    let themeScope = ThemeScope(level: .terminal)
    let themeBinding: TerminalThemeBinding
    /// Tab `dead` and connection changes for this view.
    private let watch: TerminalLinkWatch

    init(validity: String, session: TerminalSession, io: DaemonTerminalIO, themeKey: TerminalThemeKey, store: DaemonStore, surface: SurfaceID) {
        self.validity = validity
        self.session = session
        self.io = io
        self.themeKey = themeKey
        themeBinding = TerminalThemeBinding(scope: themeScope, session: session)
        themeScope.root(session.view)
        watch = TerminalLinkWatch(store: store, surface: surface, io: io, session: session)
    }

    func close() {
        watch.stop()
        session.close()
        io.close()
    }
}

/// A live WebKit page with its chrome.
final class BrowserEntry {
    let tab: any BrowserTab
    let chrome: BrowserChromeView
    /// Owns the chrome's (weak) Extensions menu handler.
    var extensionMenuHandler: (any ExtensionMenuHandling)?

    init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine(), history: (any BrowserHistoryStore)? = nil) {
        self.tab = tab
        chrome = BrowserChromeView(tab: tab, suggestionEngine: suggestionEngine)
        chrome.history = history
        // Shortcuts route through the action registry (browser* actions).
        chrome.handlesDefaultShortcuts = false
    }

    func close() {
        tab.close()
        chrome.removeFromSuperview()
    }
}
