import Foundation

/// Allocates one process-wide ordering token for every mobile focus event.
///
/// Mobile clients retain per-workspace high-water marks, so independently
/// ordered observer counters can make a valid event appear stale after focus
/// moves between windows. Main-actor isolation serializes allocation across
/// every `MobileWorkspaceListObserver` for the lifetime of the host process.
@MainActor
final class MobileWorkspaceFocusEventSequenceService {
    static let shared = MobileWorkspaceFocusEventSequenceService()

    private var sequence: UInt64 = 0

    private init() {}

    func next() -> UInt64 {
        sequence &+= 1
        return sequence
    }
}
