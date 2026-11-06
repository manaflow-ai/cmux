public import CmuxNextLayout

/// A link clicked in the Chief while Home fills the window (user 2026-11-05, the Chief window dock): the next
/// workspace this window shows goes on the stage with Home docked at `edge`, so the Chief's view stays mounted
/// (its draft, scroll and selection kept). Armed by ``WindowDockFrame/armChiefDock(home:edge:now:)`` before the
/// link opens and taken by the show that follows it; an open that ends in no show leaves it to lapse at `until`,
/// so a later sidebar pick never docks Home.
public struct ChiefDockLeave: Equatable, Sendable {
    /// `WorkspaceModel.id` of the window's Home.
    public let home: String
    /// The edge Home docks to (`home.chiefDock.edge`).
    public let edge: DockEdge
    /// After this, the arm lapses (an open that was refused or showed something else).
    public let until: ContinuousClock.Instant

    /// - Parameters:
    ///   - home: `WorkspaceModel.id` of the window's Home.
    ///   - edge: The edge Home docks to.
    ///   - until: The instant the arm lapses.
    public init(home: String, edge: DockEdge, until: ContinuousClock.Instant) {
        self.home = home
        self.edge = edge
        self.until = until
    }
}
