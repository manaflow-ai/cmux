public import Bonsplit

/// Drives a workspace's surface close commands against the live split tree:
/// closing a surface tab (optionally forcing past the close confirmation), and
/// the same close with close-history recording so the surface can be restored.
///
/// These commands are lifted one-for-one from the legacy `Workspace`
/// close bodies (`requestCloseTab(_:force:)`,
/// `requestCloseTabRecordingHistory(_:force:)`). The force-close bypass set and
/// the close-history eligibility marks stay owned by the workspace, because the
/// `BonsplitController.closeTab` call synchronously fires the workspace's
/// `BonsplitDelegate` close callbacks that read those marks mid-turn; the
/// coordinator toggles and reads them through ``SplitCloseHosting`` so this type
/// never holds the app-target `Workspace`, while the state it mutates and the
/// callbacks it triggers are always the live ones.
@MainActor
public final class SplitCloseCoordinator {
    private weak var host: (any SplitCloseHosting)?

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Attaches the workspace-side host the commands drive through.
    public func attach(host: any SplitCloseHosting) {
        self.host = host
    }

    /// Closes the surface tab, forcing past the close confirmation when
    /// `force` is set, returning whether the close took. When forced, the tab is
    /// added to the bypass set before the close and removed again if bonsplit
    /// rejects it. Lifted one-for-one from `Workspace.requestCloseTab`.
    @discardableResult
    public func requestCloseTab(_ tabId: TabID, force: Bool) -> Bool {
        guard let host else { return false }
        if force { host.insertForceCloseTabId(tabId) }
        let closed = host.closeTab(tabId)
        if force && !closed { host.removeForceCloseTabId(tabId) }
        return closed
    }

    /// Marks the closing surface close-history eligible (so the close records a
    /// restorable entry), then closes it. Returns whether the close took.
    /// Lifted one-for-one from `Workspace.requestCloseTabRecordingHistory`.
    @discardableResult
    public func requestCloseTabRecordingHistory(_ tabId: TabID, force: Bool) -> Bool {
        guard let host else { return false }
        let panelId = host.panelId(forSurfaceId: tabId)
        if let panelId {
            host.markCloseHistoryEligible(panelId: panelId)
        }

        let closed = requestCloseTab(tabId, force: force)
        return closed
    }
}
