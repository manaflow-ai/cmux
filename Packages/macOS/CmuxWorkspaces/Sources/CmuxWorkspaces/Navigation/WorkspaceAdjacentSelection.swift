public import Foundation

/// Resolves the target of a next/previous workspace cycling step over the
/// rows the sidebar shows.
public enum WorkspaceAdjacentSelection {
    /// The workspace to select when stepping from `current` by `step`
    /// (+1 next, -1 previous), wrapping at the edges of `stops`.
    ///
    /// - Parameters:
    ///   - stops: Visible row workspace ids in sidebar order.
    ///   - current: The selected workspace id.
    ///   - fallbackStop: Stop standing in for `current` when it is not a
    ///     stop itself (a hidden member's group header).
    /// - Returns: The target stop, or nil when there is no position to step
    ///   from. The target may equal `current` when it is the only stop.
    public static func target(
        stops: [UUID],
        current: UUID,
        fallbackStop: UUID? = nil,
        step: Int
    ) -> UUID? {
        guard !stops.isEmpty else { return nil }
        guard let index = stops.firstIndex(of: current)
            ?? fallbackStop.flatMap({ stops.firstIndex(of: $0) }) else { return nil }
        return stops[(index + step + stops.count) % stops.count]
    }
}
