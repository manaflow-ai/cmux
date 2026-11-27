import CmuxMobileModel

/// What the Workspaces page shows for the active team's data, one state at a
/// time (CMUX-49): the first load with nothing to show yet, the list (cached
/// or live), an account with no Mac, or a failed first load.
///
/// A cached list always wins: a launch with a snapshot shows its rows at once
/// while the team refreshes, and a refresh that fails keeps them on screen
/// instead of swapping them for the error page. Only a page with nothing to
/// show says it is loading, and it never claims "no Macs" or "no workspaces"
/// before the team's Macs are known.
public enum WorkspacesLaunchState: Equatable, Sendable {
    /// Nothing cached or listed yet: the labelled placeholder rows.
    /// `offline`: the phone has no network, so the page says it waits for one.
    case firstLoad(offline: Bool)
    /// The team's Macs are known: the list, with its own per-Mac states.
    /// `refreshFailed`: the latest refresh failed and the rows are the last known ones.
    case content(refreshFailed: Bool)
    /// The team loaded and has no Mac: the connect-a-Mac page.
    case noMacs
    /// The first load failed with nothing to show: retried on its own (placeholders, then
    /// the error page past the quiet bound; no Retry).
    case failed(offline: Bool)

    public static func resolve(team: AppStore.LoadState, hasMacs: Bool, hasWorkspaces: Bool,
                               isOffline: Bool) -> WorkspacesLaunchState {
        switch team {
        case .loading:
            return hasMacs && hasWorkspaces ? .content(refreshFailed: false) : .firstLoad(offline: isOffline)
        case .failed:
            // Macs known (a snapshot's): the list, whose rows come from the Macs'
            // own links and keep their per-Mac states.
            return hasMacs ? .content(refreshFailed: true) : .failed(offline: isOffline)
        case .loaded:
            return hasMacs ? .content(refreshFailed: false) : .noMacs
        }
    }

    /// Whether the page draws its placeholder rows: only when this phone has nothing it ever
    /// listed for the team to draw. The team's first load with no cached Macs and rows
    /// (`firstLoad`), or Macs known while no Mac has a row or a Mac line yet. Rows the phone
    /// showed before (a launch's or a team switch's cache) are drawn instead, and the Macs'
    /// answers change them in place. Leo, 2026-11-24: "holy shit this is a huge problem in
    /// ios... wer need to chase all these placeholders doen and prevent them".
    /// `listLoading`: the list is waiting with no row to show (`WorkspaceInbox.isLoading`);
    /// `hasMacLines`: it has a Mac line to show instead (`WorkspaceInbox.folds`).
    public func showsPlaceholderRows(hasMacs: Bool, listLoading: Bool, hasMacLines: Bool) -> Bool {
        switch self {
        case .firstLoad: true
        case .noMacs, .content: hasMacs && listLoading && !hasMacLines
        case .failed: false
        }
    }
}
