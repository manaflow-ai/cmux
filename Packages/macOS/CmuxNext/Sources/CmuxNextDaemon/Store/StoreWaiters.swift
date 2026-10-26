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
/// Every wait takes a timeout on an injected clock (a ``DemandTimer``, one-shot) and resumes with
/// nil when it passes or when the waiting task is cancelled.
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

    private var waiting: [Slot: [UInt64: any StoreWait]] = [:]
    /// Slots with waiters whose key changed since the last ``settleTouched(in:)``.
    private var touched: Set<Slot> = []
    /// The index was rebuilt (a full snapshot): every slot is read at the next settle.
    private var touchedAll = false
    private var nextSerial: UInt64 = 0
    /// Waiter conditions read since creation, at registration and at settle (tests: a waiter
    /// for one key reads nothing when another key changes).
    private(set) var evaluations = 0

    /// Waiters still waiting.
    var pendingCount: Int { waiting.values.reduce(0) { $0 + $1.count } }

    // MARK: Index hooks

    /// A tab record was keyed under `id`, `surface` and `resource`.
    func noteTabKeyed(id: String, surface: SurfaceID, resource: ResourceID?) {
        guard !waiting.isEmpty else { return }
        touch(.tabID(id))
        touch(.tabSurface(surface))
        if let resource { touch(.tabResource(resource)) }
    }

    /// A tab record keyed under `id` and `surface` was dropped (it may be keyed again in the same apply: a move).
    func noteTabUnkeyed(id: String, surface: SurfaceID) {
        guard !waiting.isEmpty else { return }
        touch(.tabIDGone(id))
        touch(.tabSurfaceGone(surface))
    }

    /// A workspace record was keyed under `id` and `resource`.
    func noteWorkspaceKeyed(id: String, resource: ResourceID?) {
        guard !waiting.isEmpty else { return }
        touch(.workspaceID(id))
        if let resource { touch(.workspaceResource(resource)) }
    }

    /// The index was rebuilt without dropping its records one by one.
    func noteRebuilt() {
        if !waiting.isEmpty { touchedAll = true }
    }

    /// `slot`'s state changed outside the index (loaded, connection).
    func note(_ slot: Slot) { touch(slot) }

    private func touch(_ slot: Slot) {
        if waiting[slot] != nil { touched.insert(slot) }
    }

    // MARK: Settle

    /// Reads the touched slots' conditions and resumes the waiters they satisfy. Runs once the
    /// apply that touched them is complete, so a tab that a move drops and keys again is not gone.
    func settleTouched(in store: DaemonStore) {
        guard touchedAll || !touched.isEmpty else { return }
        let slots = touchedAll ? Array(waiting.keys) : Array(touched)
        touched.removeAll()
        touchedAll = false
        for slot in slots { settle(slot, in: store) }
    }

    /// Reads `slot`'s conditions now (a change no apply wraps: the connection state).
    func settle(_ slot: Slot, in store: DaemonStore) {
        touched.remove(slot)
        guard let waiters = waiting[slot] else { return }
        for (serial, waiter) in waiters.sorted(by: { $0.key < $1.key }) {
            evaluations += 1
            if waiter.resumeIfReady(in: store) { drop(slot, serial) }
        }
    }

    // MARK: Waiting

    /// Returns `read(store)` once it is non-nil, read now and then only when `slot` changes;
    /// nil after `timeout` on `clock` or when the calling task is cancelled.
    func value<Value: Sendable>(of slot: Slot, in store: DaemonStore, timeout: Duration?, clock: any Clock<Duration>,
                                read: @escaping @MainActor (DaemonStore) -> Value?) async -> Value? {
        evaluations += 1
        if let value = read(store) { return value }
        guard !Task.isCancelled else { return nil }
        nextSerial &+= 1
        let serial = nextSerial
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                // Cancelled between the check above and here: the handler's hop finds nothing to drop.
                guard !Task.isCancelled else { return continuation.resume(returning: nil) }
                let timer = timeout.map { _ in DemandTimer(owner: "DaemonStore.waiters", clock: clock) }
                waiting[slot, default: [:]][serial] = PendingStoreWait(continuation: continuation, timer: timer, read: read)
                if let timer, let timeout {
                    timer.schedule(after: timeout) { @MainActor [weak self] in self?.abandon(slot, serial) }
                }
            }
        } onCancel: {
            // task-owner: one hop to the main actor that owns the waiters; a waiter already resumed is not found.
            Task { @MainActor [weak self] in self?.abandon(slot, serial) }
        }
    }

    private func abandon(_ slot: Slot, _ serial: UInt64) {
        guard let waiter = waiting[slot]?[serial] else { return }
        drop(slot, serial)
        waiter.abandon()
    }

    private func drop(_ slot: Slot, _ serial: UInt64) {
        waiting[slot]?[serial] = nil
        if waiting[slot]?.isEmpty == true {
            waiting[slot] = nil
            touched.remove(slot)
        }
    }
}

/// One waiter: resumed exactly once, by ``resumeIfReady(in:)`` or ``abandon()``, after which
/// ``StoreWaiters`` drops it.
@MainActor private protocol StoreWait {
    /// Resumes with the condition's value when it holds; whether it did.
    func resumeIfReady(in store: DaemonStore) -> Bool
    /// Resumes with nil (timeout, cancel).
    func abandon()
}

@MainActor private struct PendingStoreWait<Value: Sendable>: StoreWait {
    let continuation: CheckedContinuation<Value?, Never>
    let timer: DemandTimer?
    let read: @MainActor (DaemonStore) -> Value?

    func resumeIfReady(in store: DaemonStore) -> Bool {
        guard let value = read(store) else { return false }
        timer?.cancel()
        continuation.resume(returning: value)
        return true
    }

    func abandon() {
        timer?.cancel()
        continuation.resume(returning: nil)
    }
}

extension DaemonStore {
    // MARK: Keyed waits (StoreWaiters)

    /// The tab with durable id `id` once the store lists it; nil after `timeout` or on cancel.
    /// Each wait sees the visible state (pending intents included), read after the apply that changed it.
    public func waitForTab(id: String, timeout: Duration?, clock: any Clock<Duration> = ContinuousClock()) async -> TabModel? {
        await waiters.value(of: .tabID(id), in: self, timeout: timeout, clock: clock) { $0.index.tabsByID[id] }
    }

    /// The tab on `surface` once the store lists it; nil after `timeout` or on cancel.
    public func waitForTab(surface: SurfaceID, timeout: Duration?, clock: any Clock<Duration> = ContinuousClock()) async -> TabModel? {
        await waiters.value(of: .tabSurface(surface), in: self, timeout: timeout, clock: clock) { $0.index.tabsBySurface[surface] }
    }

    /// The tab with tab resource id `resource` (`tab_…`) once the store lists it; nil after `timeout` or on cancel.
    public func waitForTab(resource: ResourceID, timeout: Duration?, clock: any Clock<Duration> = ContinuousClock()) async -> TabModel? {
        await waiters.value(of: .tabResource(resource), in: self, timeout: timeout, clock: clock) { $0.index.tabsByResource[resource] }
    }

    /// The workspace with `WorkspaceModel.id` `id` once the store lists it; nil after `timeout` or on cancel.
    public func waitForWorkspace(id: String, timeout: Duration?,
                                 clock: any Clock<Duration> = ContinuousClock()) async -> WorkspaceModel? {
        await waiters.value(of: .workspaceID(id), in: self, timeout: timeout, clock: clock) { $0.index.workspacesByID[id] }
    }

    /// The workspace with public id `resource` (`ws_…`) once the store lists it; nil after `timeout` or on cancel.
    public func waitForWorkspace(resource: ResourceID, timeout: Duration?,
                                 clock: any Clock<Duration> = ContinuousClock()) async -> WorkspaceModel? {
        await waiters.value(of: .workspaceResource(resource), in: self, timeout: timeout, clock: clock) {
            $0.index.workspacesByResource[resource]
        }
    }

    /// Whether the first live snapshot applied (``isLoaded``): true once it has, false after `timeout` or on cancel.
    public func waitLoaded(timeout: Duration?, clock: any Clock<Duration> = ContinuousClock()) async -> Bool {
        let loaded: Void? = await waiters.value(of: .loaded, in: self, timeout: timeout, clock: clock) { $0.isLoaded ? () : nil }
        return loaded != nil
    }

    /// The connection state once `matches` holds for it, read now and on each change of
    /// ``connectionState``; nil after `timeout` or on cancel.
    public func waitConnection(timeout: Duration?, clock: any Clock<Duration> = ContinuousClock(),
                               where matches: @escaping @MainActor (DaemonConnectionState) -> Bool) async -> DaemonConnectionState? {
        await waiters.value(of: .connection, in: self, timeout: timeout, clock: clock) { store in
            matches(store.connectionState) ? store.connectionState : nil
        }
    }

    /// True once no tab with durable id `id` is listed (at once when none is); false after `timeout` or on cancel.
    /// A move that drops and re-adds the tab in one apply leaves it listed.
    public func waitTabGone(id: String, timeout: Duration?, clock: any Clock<Duration> = ContinuousClock()) async -> Bool {
        let gone: Void? = await waiters.value(of: .tabIDGone(id), in: self, timeout: timeout, clock: clock) {
            $0.index.tabsByID[id] == nil ? () : nil
        }
        return gone != nil
    }

    /// True once no tab on `surface` is listed (at once when none is); false after `timeout` or on cancel.
    public func waitTabGone(surface: SurfaceID, timeout: Duration?, clock: any Clock<Duration> = ContinuousClock()) async -> Bool {
        let gone: Void? = await waiters.value(of: .tabSurfaceGone(surface), in: self, timeout: timeout, clock: clock) {
            $0.index.tabsBySurface[surface] == nil ? () : nil
        }
        return gone != nil
    }
}
