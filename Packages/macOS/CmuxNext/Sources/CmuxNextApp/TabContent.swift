import AppKit
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHibernation
import enum CmuxNextLayout.LayoutTunables
import CmuxNextPages
import CmuxNextSignposts
import CmuxNextTerminal
import CmuxNextWakeups

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

    /// Hands the content's appearance readers the app's signals and its tab's node: Reduce Motion
    /// and display option changes reach a hidden tab once, when it shows.
    @MainActor func followAppearance(_ signals: AppearanceSignals, node: VisibilityNode) {
        switch self {
        case .terminal(let entry): entry.session.view.followAppearance(signals, node: node)
        case .agent(let view): view.followAppearance(signals, node: node)
        case .page(let view): (view.content as? PageWebView)?.followAppearance(signals, node: node)
        case .browser, .placeholder, .notice, .conversation: break
        }
    }

    /// Hands the content's gated SwiftUI (``VisibilityGatedHostingView``) its tab's node: it leaves the window
    /// while the tab is hidden and comes back in the show turn (feature `visibilityGatedHosting`).
    @MainActor func followVisibility(_ node: VisibilityNode, services: AppServices) {
        guard services.features.isEnabled(.visibilityGatedHosting) else { return }
        let content: NSView? = switch self {
        case .page(let view): view.content
        case .browser(let entry): entry.tab.contentView
        case .terminal, .agent, .placeholder, .notice, .conversation: nil
        }
        (content as? any VisibilityGatedContent)?.visibilityGate?.follow(node, observations: services.observations)
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

    /// How this content reports its first themed frame for a new tab's `create.tab` (``CreateTabTimings``).
    @MainActor var createTabFirstFrame: CreateTabTimings.FirstFrame {
        let identity: AnyObject = view
        switch self {
        case .terminal(let entry): return entry.session.createTabFirstFrame(content: identity)
        case .browser(let entry):
            guard let page = entry.tab as? any BrowserFirstContentFrameReporting else { return .atCommit(identity) }
            return page.createTabFirstFrame(content: identity)
        case .agent(let view): return view.createTabFirstFrame(content: identity)
        case .page(let view): return view.createTabFirstFrame(content: identity)
        case .placeholder, .notice, .conversation: return .atCommit(identity)
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
    /// A provisional view follows its tab's surface until the daemon's arrives (``TabContentCache/awaitConfirm(_:of:daemon:)``).
    var confirmation: ServiceObservation<Bool>?
    /// The daemon terminal this view shows, whatever the daemon's generation (its `term_` id or the tab's content id,
    /// else its surface handle): a replacement view of the same terminal keeps showing this one's frame (``TabContentCache/terminal(for:daemon:)``).
    var terminalIdentity: String?
    weak var confirming: TabModel? // the tab record that task watches
    /// This surface's theme scope, under its pane's workspace scope.
    let themeScope = ThemeScope(level: .terminal)
    let themeBinding: TerminalThemeBinding
    /// Tab `dead` and connection changes for this view.
    private var watch: TerminalLinkWatch
    /// The app's one main-thread scheduler, which each link watch posts its follow-ups on.
    private let mainWork: MainWorkScheduler
    /// The TextBox composer under this terminal, made the first time a TextBox action runs on it.
    var textBox: TextBoxController?

    // cx-qxxu: released with its terminal, which Cmd-T's New Tab page can withdraw while its
    // action runs; a main-actor deinit's hop traps there (cx-t7hu).
    nonisolated deinit {}

    init(validity: String, session: TerminalSession, io: DaemonTerminalIO, themeKey: TerminalThemeKey, store: DaemonStore,
         surface: SurfaceID, gate: TerminalTargetGate? = nil, mainWork: MainWorkScheduler) {
        self.validity = validity
        self.mainWork = mainWork
        self.session = session
        self.io = io
        self.gate = gate
        self.themeKey = themeKey
        themeBinding = TerminalThemeBinding(scope: themeScope, session: session)
        themeScope.root(session.view)
        watch = TerminalLinkWatch(store: store, surface: surface, io: io, session: session, mainWork: mainWork)
    }

    /// The daemon's tab replaced the provisional one: the same view and session attach to it,
    /// and keys typed meanwhile reach it in order.
    func confirm(validity: String, target: TerminalAttachment.Target, themeKey: TerminalThemeKey, store: DaemonStore) {
        guard let gate else { return }
        self.validity = validity
        self.themeKey = themeKey
        self.gate = nil
        watch.stop()
        watch = TerminalLinkWatch(store: store, surface: target.surface, io: io, session: session, mainWork: mainWork)
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

/// A live WebKit page with its chrome.
final class BrowserEntry {
    let tab: any BrowserTab
    let chrome: BrowserChromeView
    /// Owns the chrome's (weak) Extensions menu handler.
    var extensionMenuHandler: (any ExtensionMenuHandling)?

    /// `mainWork` is the app's one main-thread scheduler; `node` the tab's (`TabContentCache.node(for:)`).
    init(tab: any BrowserTab, suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine(), history: (any BrowserHistoryStore)? = nil,
         mainWork: MainWorkScheduler, node: VisibilityNode?) {
        self.tab = tab
        if let node { (tab as? any BrowserTabNodeAdopting)?.adoptNode(node) }
        // The toolbar's motion runs on the render server only with `motion.renderServer` on (off by default).
        chrome = BrowserChromeView(tab: tab, suggestionEngine: suggestionEngine, mainWork: mainWork, node: node,
                                   rendersMotionOnServer: { LayoutTunables.motionRenderServer.value })
        chrome.history = history
        // Shortcuts route through the action registry (browser* actions).
        chrome.handlesDefaultShortcuts = false
    }

    func close() {
        tab.close()
        chrome.removeFromSuperview()
    }
}

extension TabContent {
    /// This content's class, whose ``TabContentClass/discard`` says how its hidden copy is released.
    var contentClass: TabContentClass {
        switch self {
        case .terminal: .terminal
        case .browser: .browser
        case .agent: .agent
        case .page: .page
        case .placeholder: .placeholder
        case .notice: .notice
        case .conversation: .conversation
        }
    }
}
