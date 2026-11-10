/// The rows pass's computed sections of each space the window showed (SPACE SWITCH 3, F3). The pass walks every
/// workspace of the session on each space switch: the room filter, the personal order, the row mapping and the
/// member filter. This type counts those computes; it keeps nothing yet.
@MainActor
public final class SpaceRowsKeep {
    /// Runs that computed the sections, and runs that showed kept ones (tests).
    public private(set) var computes = 0
    public private(set) var hits = 0

    public init() {}

    /// The rows of space `key` for the rows pass. `compute` begins the feed's pass itself with `inputs`.
    /// `stamp`: the by-value parts the rows are made from that no observation tells of.
    public func rows(for key: ProfileKey, inputs: AnyHashable, stamp: AnyHashable, keeps: Bool, feed: SidebarRowFeed,
                     compute: () -> ([SidebarSection], Bool, Set<MachineID>)) -> ([SidebarSection], Bool, Set<MachineID>) {
        computes += 1
        return compute()
    }
}
