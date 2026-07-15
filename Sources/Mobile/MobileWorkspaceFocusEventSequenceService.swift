import Foundation

/// Allocates one monotonically increasing ordering token for every mobile focus event.
///
/// Mobile clients retain per-workspace high-water marks, so independently
/// ordered observer counters can make a valid event appear stale after focus
/// moves between windows. The production `MobileWorkspaceObserverRegistry`
/// owns one instance beside its observer collection and injects it into every
/// `MobileWorkspaceListObserver`. Main-actor isolation serializes allocation
/// across those observers.
@MainActor
final class MobileWorkspaceFocusEventSequenceService {
    private var sequence: UInt64 = 0

    init() {}

    func next() -> UInt64 {
        sequence &+= 1
        return sequence
    }
}
