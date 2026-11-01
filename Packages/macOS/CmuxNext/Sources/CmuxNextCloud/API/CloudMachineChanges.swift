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
    /// Highest ordered machine read ticket handed to CloudService. Mutation settlement uses
    /// this revision to distinguish a pre-mutation stale record from a later authoritative one.
    private var latestIssuedRead = 0
    /// Mutations accepted by the API but not yet confirmed by a terminal list record.
    /// Keeping this separate from the decoded record prevents a stale refresh from dropping
    /// the optimistic transition while the provider request is still in flight.
    private struct Mutation {
        let id: UUID
        let status: CloudMachine.Status
        let baselineUpdatedAt: Date?
        let baselineServerRevision: String?
        var baselineFailure: CloudMachine.ChangeFailure?
        /// The ordered read ticket issued when the accepted request returned.
        var requestReturnedRead: Int?
    }
    private var mutations: [String: [Mutation]] = [:]
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

    /// Runs and tracks a machine mutation. The request is tracked before awaiting the API;
    /// reconciliation uses ``pendingStatus(for:)`` to retain it over stale list records.
    public func run(_ change: CloudMachine.Status, machineID: String,
                    of holder: () -> (any CloudMachineHolder)?,
                    onRollback: @escaping @MainActor (UUID) -> Void = { _ in },
                    _ call: () async throws -> Void) async throws {
        let id = UUID()
        mutations[machineID, default: []].append(Mutation(id: id, status: change,
            baselineUpdatedAt: holder()?.machine.updatedAt,
            baselineServerRevision: holder()?.machine.serverRevision,
            baselineFailure: holder()?.machine.lastChangeFailure, requestReturnedRead: nil))
        showPending(machineID, on: holder())
        do {
            try await call()
            if let index = mutations[machineID]?.firstIndex(where: { $0.id == id }) {
                mutations[machineID]?[index].requestReturnedRead = latestIssuedRead
            }
        } catch {
            if let index = mutations[machineID]?.firstIndex(where: { $0.id == id }) {
                mutations[machineID]?.remove(at: index)
                if mutations[machineID]?.isEmpty == true { mutations[machineID] = nil }
                showPending(machineID, on: holder())
                onRollback(id)
            }
            throw error
        }
    }

    private func showPending(_ machineID: String, on holder: (any CloudMachineHolder)?) {
        holder?.machine.pendingChange = mutations[machineID]?.last?.status
        holder?.machine.pendingMutationID = mutations[machineID]?.last?.id
    }

    /// Records a read ticket before its request is sent. A mutation remembers this boundary,
    /// so a response from before the mutation cannot clear its optimistic overlay.
    public func readIssued(_ read: Int) {
        latestIssuedRead = max(latestIssuedRead, read)
    }

    /// The newest pending operation drives presentation; older operations remain tracked until
    /// their own terminal record arrives. A failed newer request exposes the older operation.
    public func applyingPending(to record: CloudMachine, read: Int? = nil) -> CloudMachine {
        if let read { readIssued(read) }
        var shown = record
        shown.failedMutationID = settleMutations(record, read: read)
        shown.pendingChange = mutations[record.id]?.last?.status
        shown.pendingMutationID = mutations[record.id]?.last?.id
        return shown
    }

    public func pendingStatus(for record: CloudMachine) -> CloudMachine.Status? {
        applyingPending(to: record).pendingChange
    }

    private func settleMutations(_ record: CloudMachine, read: Int?) -> UUID? {
        guard var outstanding = mutations[record.id] else { return nil }
        if record.status == .destroyed {
            mutations[record.id] = nil
            return nil
        }
        var failedMutationID: UUID?
        // A provider error has no operation id: attribute a new terminal error only to the
        // newest acknowledged operation. Never let one failure retire every older mutation,
        // including when both reconciliation and the poller inspect this same record.
        if let last = outstanding.last, let returnedRead = last.requestReturnedRead,
           read.map({ $0 > returnedRead }) ?? true, !record.status.isChanging,
           let failure = record.lastChangeFailure, failure != last.baselineFailure {
            failedMutationID = outstanding.removeLast().id
            for index in outstanding.indices { outstanding[index].baselineFailure = failure }
        }
        outstanding.removeAll { mutation in
            guard let returnedRead = mutation.requestReturnedRead else { return false }
            let readIsAfterAcceptance = read.map { $0 > returnedRead } ?? true
            let isNewerServerRevision: Bool = {
                if Self.newerRevision(record.serverRevision, than: mutation.baselineServerRevision) { return true }
                guard let recordRevision = record.updatedAt else { return false }
                guard let baseline = mutation.baselineUpdatedAt else { return true }
                return recordRevision > baseline
            }()
            // Completion needs a read issued after acknowledgement, but older app servers
            // need not supply updatedAt. Only an opposite terminal state (supersession)
            // requires explicit server freshness evidence as well as an ordered read.
            guard readIsAfterAcceptance else { return false }
            let superseded = read != nil && isNewerServerRevision
            switch mutation.status {
            case .pausing:
                return record.status == .paused || (record.status == .running && superseded)
            case .starting:
                return record.status == .running || (record.status == .paused && superseded)
            default: return false
            }
        }
        mutations[record.id] = outstanding.isEmpty ? nil : outstanding
        return failedMutationID
    }

    /// Compare unsigned decimal revisions without truncation, overflow or lexical digit-count mistakes.
    private static func newerRevision(_ current: String?, than previous: String?) -> Bool {
        func normalized(_ value: String?) -> String? {
            guard let value, !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            let digits = value.drop(while: { $0 == "0" })
            return digits.isEmpty ? "0" : String(digits)
        }
        guard let current = normalized(current), let previous = normalized(previous) else { return false }
        return current.count == previous.count ? current > previous : current.count > previous.count
    }

    /// A list omitted a machine (including an authoritative delete confirmation).
    public func removed(_ machineID: String) {
        mutations.removeValue(forKey: machineID)
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
        // CloudService already reconciled these records with their read tickets. Replaying
        // settlement here without tickets could let a rejected stale response clear a mutation.
        delay = Self.settleDelay
        pending = list.contains(where: \.status.isChanging) || !mutations.isEmpty
        guard pending else {
            cancelRead()
            return
        }
        schedule(refresh)
    }

    public func stop() {
        stopped = true
        pending = false
        mutations.removeAll()
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
