public import Foundation

/// A Pause, Resume or Kill of a Cloud machine, from the click until its record says where it went.
/// The cmux-next backend answers a pause or resume at once and runs the provider call after
/// (backend `domains/cloud-power.ts`), so the record reads `pausing`, `starting` or `deleting`
/// meanwhile, and a failed call puts the machine back with the record's `error`. The app does not
/// poll the machine list: while a listed machine reads so, the list is read again after
/// ``settleDelay``, at most ``settleReads`` times in a row. The reads stop once no machine is
/// changing, at the limit, when a read fails (the next one, on activation or wake, starts them
/// again) and at ``stop()``, until ``start()``.
/// What holds a Cloud machine's record in the app (its session), for ``CloudMachineChanges/run(_:of:_:)``.
@MainActor
public protocol CloudMachineHolder: AnyObject {
    var machine: CloudMachine { get set }
}

@MainActor
public final class CloudMachineChanges {
    public static let settleDelay: Duration = .seconds(3)
    public static let settleReads = 40

    private var settle: Task<Void, Never>?
    private var reads = 0
    /// Between ``stop()`` and ``start()``: a list read already on its way when the service
    /// stopped still lands in ``listed(_:refresh:)``, and must not schedule another.
    private var stopped = false

    public init() {}

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

    /// A change sent from here: the reads after it start a new run, the first one soon.
    public func began(_ refresh: @escaping @MainActor () async -> Void) {
        reads = 0
        schedule(refresh)
    }

    /// After each machine list: reads it again soon while a machine is still changing.
    public func listed(_ list: [CloudMachine], refresh: @escaping @MainActor () async -> Void) {
        guard list.contains(where: \.status.isChanging) else {
            reads = 0
            return
        }
        schedule(refresh)
    }

    public func stop() {
        stopped = true
        settle?.cancel()
        settle = nil
        reads = 0
    }

    private func schedule(_ refresh: @escaping @MainActor () async -> Void) {
        guard !stopped, settle == nil, reads < Self.settleReads else { return }
        reads += 1
        // task-owner: one delayed list read; stop() cancels it, and the list it reads decides on the next
        settle = Task { [weak self] in
            // wakeup-allow: a bounded, cancellable re-read while a machine's pause, resume or delete lands
            try? await ContinuousClock().sleep(for: Self.settleDelay)
            guard let self, !Task.isCancelled else { return }
            settle = nil
            await refresh()
        }
    }
}
