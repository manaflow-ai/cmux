/// A set of hover card sources that share one card window in a window: a card moves (slides and
/// morphs) between them, and never to a source outside the set.
///
/// A source with no group is a set of its own (a pane's tab strip): another source's card gets a
/// new card window and the last one fades out where it is (user 2026-11-09, no card flies from the
/// sidebar to a pane's tabs). The sidebar's sources and its owner cards (Update Ready, Updated, a
/// pull request badge) are one group, so going from the update card to a workspace row morphs the
/// one card (Lawrence 2026-10-20).
///
/// ```swift
/// var hoverCardGroup: HoverCardGroup? { .sidebar }
/// ```
public struct HoverCardGroup: Hashable, Sendable {
    /// The group's name (debug output).
    public let name: String

    /// A group named `name`.
    ///
    /// - Parameter name: Unique among the app's groups.
    public init(_ name: String) {
        self.name = name
    }

    /// The sidebar: its workspace rows, its rail and its owner cards.
    public static let sidebar = HoverCardGroup("sidebar")
}
