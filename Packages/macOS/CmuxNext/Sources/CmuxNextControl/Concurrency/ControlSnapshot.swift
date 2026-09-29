public import CmuxNextSettings
import Darwin
import Synchronization

/// An immutable picture of everything read-only control methods answer
/// from (plans/cmux-next/architecture.md section 5a).
///
/// The main actor builds it after each model settle and publishes it with
/// one atomic swap; connection tasks read it off the main actor. Fields are
/// value types with copy-on-write storage, so a read is a retain, not a
/// deep copy, and a reader never observes a half-applied update.
public struct ControlSnapshot: Sendable {
    /// Increments on every publish.
    public internal(set) var generation: UInt64 = 0
    /// `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` at publish time.
    public internal(set) var publishedAtUptimeNanos: UInt64 = 0
    public var catalog: ControlCatalog = .empty
    public var topology = ControlTopology()
    /// The loaded cmux.json document, or nil before the first load.
    public var settings: JSONValue?

    public init() {}

    public static let empty = ControlSnapshot()
}

/// The atomic reference that publishes ``ControlSnapshot``s. Writers are
/// the main actor (topology, settings) and the registry bridge (catalog);
/// readers are connection tasks. The lock is held only for a struct copy.
public final class ControlSnapshotStore: Sendable {
    private let state = Mutex(ControlSnapshot())

    public init() {}

    /// The latest published snapshot.
    public var current: ControlSnapshot { state.withLock { $0 } }

    /// Applies `update` to a copy of the current snapshot and publishes the
    /// result. Build expensive values before calling: the lock is held for
    /// the closure's duration.
    @discardableResult
    public func publish(_ update: (inout ControlSnapshot) -> Void) -> UInt64 {
        state.withLock { snapshot in
            update(&snapshot)
            snapshot.generation &+= 1
            snapshot.publishedAtUptimeNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            return snapshot.generation
        }
    }
}
