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
    /// The first load failed with nothing to show: the error page with Retry.
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

    /// The navigation subtitle may say "Updating…" only over rows: on the
    /// first load the page itself says it is loading (one indicator, not two).
    public var allowsUpdatingSubtitle: Bool {
        if case .content(refreshFailed: false) = self { return true }
        return false
    }
}
