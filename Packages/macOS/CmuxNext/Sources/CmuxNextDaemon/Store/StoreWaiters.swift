import CmuxNextWakeups
import Foundation

/// Keyed waits on the store's records (plans/cmux-next/chrome-parity/p06-scheduler.md, section C,
/// task 027): a wait for one tab, workspace or state change is filed under the key that can
/// satisfy it, and only a change of that key reads its condition again.
///
/// A predicate wait (an `ObservationStream` over a lookup) re-evaluates on every tab-list change,
/// so N waiters cost N reads per insert of any tab. Here ``StoreIndex`` tells the waiters which
/// keys it (re)keyed or dropped; the slots of those keys are read once, after the apply, when
/// the visible state is complete (`DaemonStore.publishTabListChange`). Chromium signals its
/// waiters from the change itself the same way, never from a poll (`base/one_shot_event.h`,
/// `TabStripModelObserver::OnTabStripModelChanged` in chrome/browser/ui/tabs/tab_strip_model_observer.h).
///
/// Every wait has a timeout on the main thread's one deadline queue; the waits themselves are a
/// ``KeyedWaiters`` (CmuxNextWakeups), the engine a page's waits share (`PageWaiters`, task 028).
/// This type adds what the index needs: the slots an apply touched are settled once, after it.
@MainActor final class StoreWaiters {
    /// The key a waiter is filed under: the index key whose change can satisfy it.
    enum Slot: Hashable, Sendable {
        case tabID(String)
        case tabSurface(SurfaceID)
        case tabResource(ResourceID)
        case tabIDGone(String)
        case tabSurfaceGone(SurfaceID)
        case workspaceID(String)
        case workspaceResource(ResourceID)
        case loaded
        case connection
    }

    /// The `WakeupLedger` owner of the waits' timeouts.
    static let deadlineOwner = "DaemonStore.waiters"

    private let keyed: KeyedWaiters<Slot, DaemonStore>
    /// Slots with waiters whose key changed since the last ``settleTouched(in:)``.
    private var touched: Set<Slot> = []
    /// The index was rebuilt (a full snapshot): every slot is read at the next settle.
    private var touchedAll = false
    /// Waiter conditions read since creation, at registration and at settle (tests: a waiter
    /// for one key reads nothing when another key changes).
    var evaluations: Int { keyed.evaluations }
    /// Waiters still waiting.
    var pendingCount: Int { keyed.pendingCount }

    /// - Parameter deadlines: Where the waits' timeouts go: the main thread's one deadline queue.
    init(deadlines: AlignedWakeups) {
        keyed = KeyedWaiters(deadlines: deadlines, deadlineOwner: Self.deadlineOwner)
    }

    // MARK: Index hooks

    /// A tab record was keyed under `id`, `surface` and `resource`.
    func noteTabKeyed(id: String, surface: SurfaceID, resource: ResourceID?) {
        guard !keyed.isEmpty else { return }
        touch(.tabID(id))
        touch(.tabSurface(surface))
        if let resource { touch(.tabResource(resource)) }
    }

    /// A tab record keyed under `id` and `surface` was dropped (it may be keyed again in the same apply: a move).
    func noteTabUnkeyed(id: String, surface: SurfaceID) {
        guard !keyed.isEmpty else { return }
        touch(.tabIDGone(id))
        touch(.tabSurfaceGone(surface))
    }

    /// A workspace record was keyed under `id` and `resource`.
    func noteWorkspaceKeyed(id: String, resource: ResourceID?) {
        guard !keyed.isEmpty else { return }
        touch(.workspaceID(id))
        if let resource { touch(.workspaceResource(resource)) }
    }

    /// The index was rebuilt without dropping its records one by one.
    func noteRebuilt() {
        if !keyed.isEmpty { touchedAll = true }
    }

    /// `slot`'s state changed outside the index (loaded, connection).
    func note(_ slot: Slot) { touch(slot) }

    private func touch(_ slot: Slot) {
        if keyed.hasWaiters(slot) { touched.insert(slot) }
    }

    // MARK: Settle

    /// Reads the touched slots' conditions and resumes the waiters they satisfy. Runs once the
    /// apply that touched them is complete, so a tab that a move drops and keys again is not gone.
    func settleTouched(in store: DaemonStore) {
        guard touchedAll || !touched.isEmpty else { return }
        let slots = touchedAll ? keyed.slots : Array(touched)
        touched.removeAll()
        touchedAll = false
        for slot in slots { keyed.settle(slot, with: store) }
    }

    /// Reads `slot`'s conditions now (a change no apply wraps: the connection state).
    func settle(_ slot: Slot, in store: DaemonStore) {
        touched.remove(slot)
        keyed.settle(slot, with: store)
    }

    // MARK: Waiting

    /// Returns `read(store)` once it is non-nil, read now and then only when `slot` changes;
    /// nil after `timeout` or when the calling task is cancelled.
    func value<Value: Sendable>(of slot: Slot, in store: DaemonStore, timeout: Duration,
                                read: @escaping @MainActor (DaemonStore) -> Value?) async -> Value? {
        await keyed.value(of: slot, now: store, timeout: timeout, read: read)
    }

    /// Returns once at least `count` waiters are waiting (tests: a wait started in a task has filed itself).
    func untilPending(_ count: Int) async {
        await keyed.untilPending(count)
    }
}

extension DaemonStore {
    // MARK: Keyed waits (StoreWaiters)

    /// The tab with durable id `id` once the store lists it; nil after `timeout` or on cancel.
    /// Each wait sees the visible state (pending intents included), read after the apply that changed it.
    public func waitForTab(id: String, timeout: Duration) async -> TabModel? {
        await waiters.value(of: .tabID(id), in: self, timeout: timeout) { $0.index.tabsByID[id] }
    }

    /// The tab on `surface` once the store lists it; nil after `timeout` or on cancel.
    public func waitForTab(surface: SurfaceID, timeout: Duration) async -> TabModel? {
        await waiters.value(of: .tabSurface(surface), in: self, timeout: timeout) { $0.index.tabsBySurface[surface] }
    }

    /// The tab with tab resource id `resource` (`tab_…`) once the store lists it; nil after `timeout` or on cancel.
    public func waitForTab(resource: ResourceID, timeout: Duration) async -> TabModel? {
        await waiters.value(of: .tabResource(resource), in: self, timeout: timeout) { $0.index.tabsByResource[resource] }
    }

    /// The workspace with `WorkspaceModel.id` `id` once the store lists it; nil after `timeout` or on cancel.
    public func waitForWorkspace(id: String, timeout: Duration) async -> WorkspaceModel? {
        await waiters.value(of: .workspaceID(id), in: self, timeout: timeout) { $0.index.workspacesByID[id] }
    }

    /// The workspace with public id `resource` (`ws_…`) once the store lists it; nil after `timeout` or on cancel.
    public func waitForWorkspace(resource: ResourceID, timeout: Duration) async -> WorkspaceModel? {
        await waiters.value(of: .workspaceResource(resource), in: self, timeout: timeout) {
            $0.index.workspacesByResource[resource]
        }
    }

    /// Whether the first live snapshot applied (``isLoaded``): true once it has, false after `timeout` or on cancel.
    public func waitLoaded(timeout: Duration) async -> Bool {
        let loaded: Void? = await waiters.value(of: .loaded, in: self, timeout: timeout) { $0.isLoaded ? () : nil }
        return loaded != nil
    }

    /// The connection state once `matches` holds for it, read now and on each change of
    /// ``connectionState``; nil after `timeout` or on cancel.
    public func waitConnection(timeout: Duration,
                               where matches: @escaping @MainActor (DaemonConnectionState) -> Bool) async -> DaemonConnectionState? {
        await waiters.value(of: .connection, in: self, timeout: timeout) { store in
            matches(store.connectionState) ? store.connectionState : nil
        }
    }

    /// True once no tab with durable id `id` is listed (at once when none is); false after `timeout` or on cancel.
    /// A move that drops and re-adds the tab in one apply leaves it listed.
    public func waitTabGone(id: String, timeout: Duration) async -> Bool {
        let gone: Void? = await waiters.value(of: .tabIDGone(id), in: self, timeout: timeout) {
            $0.index.tabsByID[id] == nil ? () : nil
        }
        return gone != nil
    }

    /// True once no tab on `surface` is listed (at once when none is); false after `timeout` or on cancel.
    public func waitTabGone(surface: SurfaceID, timeout: Duration) async -> Bool {
        let gone: Void? = await waiters.value(of: .tabSurfaceGone(surface), in: self, timeout: timeout) {
            $0.index.tabsBySurface[surface] == nil ? () : nil
        }
        return gone != nil
    }
}
