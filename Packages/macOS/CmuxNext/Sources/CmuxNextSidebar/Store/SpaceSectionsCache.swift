import Observation

/// The rows of other spaces for the sidebar's swipe pages (R99): read once
/// when a swipe reaches a space, kept until the observed data that built
/// them (daemon stores, personal rows, window membership) changes. The
/// change clears only that entry; nothing polls.
@MainActor public final class SpaceSectionsCache {
    private var entries: [ProfileKey: [SidebarSection]] = [:]
    public private(set) var computations = 0

    public init() {}

    public func sections(for key: ProfileKey, compute: () -> [SidebarSection]) -> [SidebarSection] {
        if let hit = entries[key] { return hit }
        computations += 1
        let value = withObservationTracking(compute) { [weak self] in
            Task { @MainActor in self?.entries[key] = nil }
        }
        entries[key] = value
        return value
    }
}
