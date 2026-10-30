import AppKit

/// The running app's Dock tile (`NSApp.dockTile`), looked up at each write, so a
/// ``DockBadge`` made before the application object exists writes nothing instead of trapping.
@MainActor
public final class AppDockTile: DockBadgeTile {
    /// Makes the tile of the running app.
    public init() {}

    /// The Dock tile's badge label. Reading it asks the Dock and can block: ``DockBadge`` never does.
    public var badgeLabel: String? {
        get { NSApp?.dockTile.badgeLabel }
        set { NSApp?.dockTile.badgeLabel = newValue }
    }
}
