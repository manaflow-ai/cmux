/// Where ``DockBadge`` writes its label: ``AppDockTile`` in the app, a recorder in tests.
@MainActor
public protocol DockBadgeTile: AnyObject {
    /// The label the Dock shows on the app's icon; nil shows none.
    var badgeLabel: String? { get set }
}
