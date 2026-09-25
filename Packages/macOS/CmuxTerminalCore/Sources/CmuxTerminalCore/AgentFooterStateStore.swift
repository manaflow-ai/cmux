public import Combine
public import Foundation

/// Main-actor owner for the per-surface agent footer lifecycle.
///
/// PTY callbacks submit updates through the app's main-actor bridge. The lease
/// token makes those updates safe across teardown and a later surface reuse:
/// an old tee can never write into a new surface instance with the same ID.
@MainActor
public final class AgentFooterStateStore: ObservableObject {
    /// Identifies one installed PTY tee for one surface instance.
    public struct Lease: Equatable, Sendable {
        public let surfaceID: UUID
        fileprivate let generation: UUID

        fileprivate init(surfaceID: UUID) {
            self.surfaceID = surfaceID
            self.generation = UUID()
        }
    }

    private struct Entry {
        let lease: Lease
        var state: AgentFooterState?
        var retired = false
        var released = false
    }

    /// The live and retiring surface entries. Publishing this dictionary makes
    /// the store itself the UI observation boundary; snapshots and updates
    /// cannot diverge through a second mirrored state collection.
    @Published private var entries: [UUID: Entry] = [:]

    /// Creates an empty state store.
    public init() {}

    /// Shared inert store for terminal hosts that do not publish footer data.
    public static let empty = AgentFooterStateStore()

    /// Starts a new surface instance and invalidates any older lease for its ID.
    public func activate(surfaceID: UUID) -> Lease {
        let lease = Lease(surfaceID: surfaceID)
        entries[surfaceID] = Entry(lease: lease, state: nil)
        return lease
    }

    /// Returns the current snapshot for a live or recently retired surface.
    public func snapshot(for surfaceID: UUID) -> AgentFooterState? {
        entries[surfaceID]?.state
    }

    /// Applies a PTY update when it belongs to the currently active lease.
    ///
    /// A `nil` state is a valid clear operation. Retired or stale leases are
    /// ignored, which prevents late PTY callbacks from restoring old UI state.
    @discardableResult
    public func update(_ state: AgentFooterState?, for lease: Lease) -> Bool {
        guard var entry = entries[lease.surfaceID],
              entry.lease == lease,
              !entry.retired else {
            return false
        }
        entry.state = state
        entries[lease.surfaceID] = entry
        return true
    }

    /// Marks a surface as retired and clears its visible snapshot.
    @discardableResult
    public func retire(surfaceID: UUID) -> Bool {
        guard var entry = entries[surfaceID], !entry.retired else { return false }
        entry.retired = true
        entry.state = nil
        if entry.released {
            entries.removeValue(forKey: surfaceID)
        } else {
            entries[surfaceID] = entry
        }
        return true
    }

    /// Records tee release and removes retired state when the last owner is gone.
    public func release(_ lease: Lease) {
        guard var entry = entries[lease.surfaceID], entry.lease == lease else { return }
        guard entry.retired else {
            entry.released = true
            entries[lease.surfaceID] = entry
            return
        }
        entries.removeValue(forKey: lease.surfaceID)
    }
}

/// The lifecycle surface used by a terminal runtime to publish pane footer
/// snapshots without owning the store or its UI delivery mechanism.
public protocol AgentFooterStatePublishing: AnyObject, Sendable {
    /// The observable store used by the terminal-pane UI.
    @MainActor
    var stateStore: AgentFooterStateStore { get }

    /// Starts a new lease for a surface instance.
    @MainActor
    func activate(surfaceID: UUID) -> AgentFooterStateStore.Lease

    /// Applies a snapshot for a leased surface instance.
    func post(state: AgentFooterState?, for lease: AgentFooterStateStore.Lease)

    /// Reads the latest snapshot for initial panel rendering.
    @MainActor
    func snapshot(for surfaceID: UUID) -> AgentFooterState?

    /// Retires a surface and clears its visible snapshot.
    @MainActor
    func retire(surfaceID: UUID)

    /// Balances a tee lease after its callback context is released.
    @MainActor
    func release(_ lease: AgentFooterStateStore.Lease)
}
