public import Foundation

/// A Pause, Resume or Kill of a Cloud machine, from the click until its record says where it went.
/// The cmux-next backend answers a pause or resume at once and runs the provider call after
/// (backend `domains/cloud-power.ts`), so the record reads `pausing`, `starting` or `deleting`
/// meanwhile, and a failed call puts the machine back with the record's `error`. The app does not
/// poll the machine list continuously: reads continue only while an operation is pending.
/// Successful lists use ``settleDelay``; failed reads back off to at most 30 seconds. A settled
/// list or ``stop()`` ends the run. There is no client deadline for an unbounded provider operation.
/// What holds a Cloud machine's record in the app (its session), for ``CloudMachineChanges/run(_:of:_:)``.
@MainActor
public protocol CloudMachineHolder: AnyObject {
    var machine: CloudMachine { get set }
}

@MainActor
public final class CloudMachineChanges {
    public static let settleDelay: Duration = .seconds(3)
    private let sleep: @MainActor (Duration) async throws -> Void
    private var settle: Task<Void, Never>?
    private var pending = false
    private var delay = CloudMachineChanges.settleDelay
    private var listRevision: UInt64 = 0
    private var lifecycle: UInt64 = 0
    /// Between ``stop()`` and ``start()``: a list read already on its way when the service
    /// stopped still lands in ``listed(_:refresh:)``, and must not schedule another.
    private var stopped = false

    public convenience init() {
        self.init(sleep: CloudMachineChanges.sleepForTransition)
    }

    public init(sleep: @escaping @MainActor (Duration) async throws -> Void) {
        self.sleep = sleep
    }

    private static func sleepForTransition(_ delay: Duration) async throws {
        // wakeup-allow: cancellable transition refresh with bounded failure backoff
        try await ContinuousClock().sleep(for: delay)
    }

    deinit { settle?.cancel() }

    /// The service started (again): lists may schedule reads.
    public func start() {
        stopped = false
    }

    /// A list read is due.
    public var isSettling: Bool { settle != nil }

    /// Runs `call` while the machine `of` finds shows `change` (``CloudMachine/pendingChange``).
    /// A call that fails shows the record again, unless a newer change (a Kill sent while this
    /// pause waited) took its place; one that worked shows the change until the next list
    /// replaces the record. `of` is asked again after the call: the machine may be gone.
    public static func run(_ change: CloudMachine.Status, of holder: () -> (any CloudMachineHolder)?,
                           _ call: () async throws -> Void) async throws {
        holder()?.machine.pendingChange = change
        do {
            try await call()
        } catch {
            if let shown = holder(), shown.machine.pendingChange == change { shown.machine.pendingChange = nil }
            throw error
        }
    }

    /// A change sent from here: a read already in flight cannot settle this newer operation.
    public func began(_ refresh: @escaping @MainActor () async -> Void) {
        guard !stopped, !Task.isCancelled else { return }
        cancelRead()
        pending = true
        delay = Self.settleDelay
        schedule(refresh)
    }

    /// After each successful machine list: retain reads only while a machine is changing.
    public func listed(_ list: [CloudMachine], refresh: @escaping @MainActor () async -> Void) {
        // began/stop cancel the old task, including callbacks delivered from inside its refresh.
        guard !stopped, !Task.isCancelled else { return }
        listRevision += 1
        delay = Self.settleDelay
        pending = list.contains(where: \.status.isChanging)
        guard pending else {
            cancelRead()
            return
        }
        schedule(refresh)
    }

    public func stop() {
        stopped = true
        pending = false
        delay = Self.settleDelay
        cancelRead()
    }

    private func cancelRead() {
        lifecycle += 1
        settle?.cancel()
        settle = nil
    }

    private func schedule(_ refresh: @escaping @MainActor () async -> Void) {
        guard !stopped, pending, settle == nil else { return }
        let ticket = lifecycle, wait = delay, sleep = self.sleep
        // task-owner: one delayed read; settled lists and stop() cancel it. A failed read retries
        // with a capped delay while the operation remains pending, with no provider deadline invented.
        settle = Task { [weak self] in
            // wakeup-allow: cancellable transition refresh with bounded failure backoff
            do { try await sleep(wait) } catch { return }
            guard let self, !Task.isCancelled, lifecycle == ticket, pending, !stopped else { return }
            let revision = listRevision
            await refresh()
            guard !Task.isCancelled, lifecycle == ticket, !stopped else { return }
            settle = nil
            if listRevision != revision {
                delay = Self.settleDelay
            } else {
                delay = min(delay * 2, .seconds(30))
            }
            schedule(refresh)
        }
    }
}
