public import CmuxNextDaemon
public import CmuxNextDaemonService

/// What Stash (a native OneTab, `stash-v1`) needs from the App: this Mac's daemon and the App's
/// windows. The App implements it; everything else lives here.
public protocol StashHost: AnyObject {
    /// This Mac's daemon: the only one that keeps stashes.
    var localDaemon: DaemonService { get }
    /// The pane a page whose own pane is gone reopens in: the active window's focused pane on
    /// this Mac's daemon.
    var stashRestorePane: ResourceID? { get }
    /// Shows reopened pages: their workspace in the active window, the first tab selected.
    func showRestored(_ reopened: StateResourceClient.ReopenedItem, asWorkspace: Bool)
    /// The browser engine imported pages reopen in (`browser.defaultEngine`).
    var stashImportEngine: String { get }
}
