/// Who asked for a sidebar change (calm-sidebar-movement, Lawrence 2026-10-20: "my sidebar is moving
/// too much and it shows me the animation when it moves. It distracts me").
///
/// A change this app's user asked for (a click, a drag, a menu, the palette, a shortcut) may move
/// rows on a spring. A change nobody here asked for (an agent's status, a title, a new workspace
/// from the CLI, a group an agent fills, another client) shows in place, with no motion.
public extension SidebarModel {
    /// How long after a user's request its change may still arrive (a daemon round trip under load
    /// takes up to about a second) and move rows on a spring.
    static let userIntentWindow: Duration = .seconds(2)

    /// This app's user asked for a sidebar change: the change that shows it may animate.
    func noteUserIntent() { userIntentAt = userIntentClock() }

    /// Whether a change shown now follows a user's request (`noteUserIntent`) closely enough to animate.
    var followsUserIntent: Bool {
        guard let userIntentAt else { return false }
        return userIntentClock() - userIntentAt <= Self.userIntentWindow
    }

    /// Whether the structural change shown now may move rows: it follows a user's request, and it is not a quiet
    /// attention re-sort that landed inside that request's window.
    var structureFollowsUserIntent: Bool { followsUserIntent && quietRevision != sectionsRevision }
}
