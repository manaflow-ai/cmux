import CmuxNextCompat

/// Set once anything a tracked read observed changes (`withObservationTracking`'s `onChange`, which
/// runs inside the mutation on any thread), so a value kept for a drag is rebuilt only then.
public nonisolated final class TabDragChangeFlag: Sendable {
    private let changed = Mutex(false)

    public init() {}

    public var isSet: Bool { changed.withLock { $0 } }

    public func set() {
        changed.withLock { $0 = true }
    }
}
