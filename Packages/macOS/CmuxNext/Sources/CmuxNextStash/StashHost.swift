public import CmuxNextActions
public import CmuxNextAgentPane
public import CmuxNextDaemon
public import CmuxNextDaemonService

/// What Stash (a native OneTab, `stash-v1`) needs from the App: this Mac's daemon, the action
/// registry, and the App's windows and pages. The App implements it; everything else lives here.
public protocol StashHost: AnyObject {
    var registry: ActionRegistry { get }
    /// This Mac's daemon: the only one that keeps stashes.
    var localDaemon: DaemonService { get }
    /// The tab a Stash action acts on (its target, else the focused pane's selected tab).
    func stashOrigin(_ invocation: ActionInvocation) -> StashOrigin?
    /// The pane a page whose own pane is gone reopens in: the active window's focused pane on
    /// this Mac's daemon.
    var stashRestorePane: ResourceID? { get }
    /// Shows reopened pages: their workspace in the active window, the first tab selected.
    func showRestored(_ reopened: StateResourceClient.ReopenedItem, asWorkspace: Bool)
    /// The browser engine imported pages reopen in (`browser.defaultEngine`).
    var stashImportEngine: String { get }
    /// Shows the Stashed page in the active window; its page key.
    @discardableResult func showStashedPage() -> String?
    /// Every agent page (New Tab pages hear the stash count), by key.
    var stashCountPages: [String: AgentPaneView] { get }
    /// Agent pages outside a tab (the floating composer), which hear the count too.
    var stashCountStandalonePages: [AgentPaneView] { get }
}

/// The tab a Stash action acts on and where it sits.
public struct StashOrigin {
    public let tab: TabModel
    public let workspace: WorkspaceModel?
    public let daemon: DaemonService
    /// The pane's tabs in strip order (groups drawn together, pinned first).
    public let strip: [TabModel]

    public init(tab: TabModel, workspace: WorkspaceModel?, daemon: DaemonService, strip: [TabModel]) {
        self.tab = tab
        self.workspace = workspace
        self.daemon = daemon
        self.strip = strip
    }
}
