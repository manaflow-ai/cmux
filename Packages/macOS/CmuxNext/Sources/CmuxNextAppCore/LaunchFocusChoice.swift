/// What a person or the API chose in the launch window before the saved state loaded (launch-TTI round 11).
///
/// The launch window shows the saved front window at once (`LaunchSnapshotWindow`), and the async restore later adopts
/// that same record (`WindowManager.adoptLaunchWindow`). The adopt used to reset the shown workspace and each pane's
/// tab to the saved ones, so a `workspace focus` or a sidebar click made in between was undone: the front window went back to
/// the saved workspace. The restore now keeps such a choice: it applies the saved record, then shows the picked
/// workspace again. Constant cost: one compare. Tab selections are not kept: a pane's selection also moves on its own
/// while the provisional tree resolves, which is no one's choice.
public struct LaunchFocusChoice: Equatable, Sendable {
    /// The workspace the launch window showed when it opened.
    public let shownAtLaunch: String?

    public init(shownAtLaunch: String?) { self.shownAtLaunch = shownAtLaunch }

    /// The workspace to show after the adopt: the one shown now when it changed since launch, is not nil, and the
    /// adopted window lists it (`listed`); else nil, and the saved one stays.
    public func keptWorkspace(now: String?, listed: (String) -> Bool) -> String? {
        guard let now, now != shownAtLaunch, listed(now) else { return nil }
        return now
    }
}
