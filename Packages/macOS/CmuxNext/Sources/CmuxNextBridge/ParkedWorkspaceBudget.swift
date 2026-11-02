/// How many workspaces a window keeps parked (mounted, paused) after it showed them (issue 26046):
/// visiting 400 workspaces kept 400 controllers, layout trees, panes and strips until critical
/// memory pressure, and the app's footprint grew with every one (310 MiB to 868 MiB). Past
/// ``capacity`` the least recently parked one leaves (as under critical pressure) and mounts again
/// when shown. 32 keeps the switches between a working set warm: the old budget of 8 made cycling 9
/// workspaces a cold mount on every switch (cx-8w027.5).
public struct ParkedWorkspaceBudget: Hashable, Sendable {
    public var capacity: Int

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public static let standard = ParkedWorkspaceBudget(capacity: 32)

    /// The parked workspaces to tear down, least recently parked first: all but the `capacity` most
    /// recent, never one in `kept` (the one under a top page, the ones on screen beside the shown one).
    public func evictions(parked: [(id: String, serial: UInt64)], kept: Set<String>) -> [String] {
        let over = parked.count - capacity
        guard over > 0 else { return [] }
        return parked.filter { !kept.contains($0.id) }.sorted { $0.serial < $1.serial }.prefix(over).map(\.id)
    }
}
