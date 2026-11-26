public import CmuxNextDaemon
public import Foundation

/// A Pause, Resume or Kill of a Cloud machine, from the click until its record says where it went.
/// The cmux-next backend answers a pause or resume at once and runs the provider call after
/// (backend `domains/cloud-power.ts`), so the record reads `pausing`, `starting` or `deleting`
/// meanwhile, and a failed call puts the machine back with the record's `error`. The app does not
/// poll the machine list continuously: reads continue only while an operation is pending.
/// Successful lists use ``settleDelay``; failed reads back off to at most 30 seconds. A settled
/// list or ``stop()`` ends the run. There is no client deadline for an unbounded provider operation.
/// A machine whose state is pushed (the daemon holds a state socket for each machine a list shows, `apps-machine-state-watch`,
/// and tells the app with `apps-cloud-machine` events) is not read at all: its push brings the record, and the reads stay
/// only for machines without a live push.
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
    /// The pending overlay (cmux-cloud-machine `changes::Changes`): the mutations accepted by the API but not yet
    /// confirmed by a terminal record, and the highest read ticket handed out. Rust holds its rules; this is its JSON.
    private var state: JSONValue = .object([:])
    /// Names the machines to watch to the daemon, which holds their state sockets (nil: the classic client, nothing is pushed).
    private var watch: (@MainActor ([CloudMachine]) async -> Void)?
    /// The machines whose push is live (a frame reached the Cloud app server), from the daemon's events.
    public private(set) var live: Set<String> = []
    private var watched: [CloudMachine] = []
    private var record: @MainActor (CloudMachine) -> Void = { _ in }
    /// The watch requests, one after another in the order they were made.
    private var sending: Task<Void, Never>?
    /// Bumped by ``stop()``: a watch queued before it is not sent after it.
    private var watchEpoch: UInt64 = 0
    /// The last list's refresh: what a lost push falls back to.
    private var lastRefresh: (@MainActor () async -> Void)?
    /// The machines the pending settle read is for; nil when it is for no one machine (a create, a lost push).
    private var pendingMachines: Set<String>?
    /// Takes `watch` (see ``CloudAPIClient/stateWatch(baseURL:connection:)``) and where pushed records are shown; the next
    /// list names its machines.
    public func startPush(_ watch: (@MainActor ([CloudMachine]) async -> Void)?, record: @escaping @MainActor (CloudMachine) -> Void) {
        guard self.watch == nil, let watch else { return }
        self.record = record
        self.watch = watch
    }

    /// Queues a watch behind the ones before it. `superseding` (a stop) drops every watch still queued, so none of
    /// them opens sockets after the stop's empty list closed them; one already sending finishes first.
    private func send(_ machines: [CloudMachine], superseding: Bool = false) {
        guard let watch else { return }
        if superseding { watchEpoch &+= 1 }
        let previous = sending, epoch = watchEpoch
        // task-owner: kept in `sending`; each waits for the one before it
        sending = Task { [weak self] in
            await previous?.value
            guard let self, self.watchEpoch == epoch else { return }
            await watch(machines)
        }
    }

    /// The daemon's connection is new (a restart): it holds no sockets of the last one, so the watched list goes again.
    public func rewatch() {
        daemonDisconnected()
        guard !stopped, !watched.isEmpty else { return }
        send(watched)
    }

    /// An `apps-cloud-machine` event: a machine's record, or its push going live or lost.
    public func machineState(_ event: DaemonEvent) {
        guard case .unknown("apps-cloud-machine", let payload) = event, !stopped,
              let machine = payload["machine"]?.stringValue, let kind = payload["kind"]?.stringValue else { return }
        switch kind {
        case "record":
            // The crate's record: timestamps in epoch milliseconds, as every CloudMachineRules reply.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard let value = payload["record"], let data = try? JSONEncoder().encode(value),
                  let shown = try? decoder.decode(CloudMachine.self, from: data) else { return }
            record(shown)
        case "live":
            live.insert(machine)
            pushWentLive()
        case "lost":
            pushesLost([machine])
        default:
            return
        }
    }

    /// The daemon's connection closed: it drops every socket of that client without a `lost`, so every live push is lost.
    public func daemonDisconnected() {
        pushesLost(live)
    }

    /// Pushes stopped for `machines`: their reads come back until a socket delivers again, from the last list's refresh.
    private func pushesLost(_ machines: Set<String>) {
        let lost = live.intersection(machines)
        guard !lost.isEmpty else { return }
        live.subtract(lost)
        guard let refresh = lastRefresh else { return }
        let others = pending ? pendingMachines : []
        began(refresh)
        // The read is for these machines (and any already waiting on one), so their pushes coming back can end it.
        pendingMachines = others.map { $0.union(lost) }
    }

    /// Whether a machine's record is pushed now; such a machine keeps no settle read going.
    public func isPushed(_ machineID: String) -> Bool { live.contains(machineID) }
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
        let shown = changes("cloud_machine_changes_begin", Begin(state: state, machine: machineID, id: id.uuidString, change: change,
                                                                 baseline: holder()?.machine), as: Answer.self)
        show(shown?.shown, on: holder())
        do {
            try await call()
            _ = changes("cloud_machine_changes_returned", Step(state: state, machine: machineID, id: id.uuidString), as: Answer.self)
        } catch {
            if let answer = changes("cloud_machine_changes_rollback", Step(state: state, machine: machineID, id: id.uuidString), as: Answer.self),
               answer.rolledBack == true {
                show(answer.shown, on: holder())
                onRollback(id)
            }
            throw error
        }
    }

    /// A person's change (`user`) runs as the tracked ``run(_:machineID:of:onRollback:_:)``; a script's hint (a typing
    /// prewarm, cmux#34974) runs untracked, so no overlay holds back the person's connect and a refused hint stays retryable.
    public func run(_ change: CloudMachine.Status, machineID: String, origin: AppsRunRequest.Origin,
                    of holder: () -> (any CloudMachineHolder)?,
                    onRollback: @escaping @MainActor (UUID) -> Void = { _ in },
                    _ call: () async throws -> Void) async throws {
        guard origin != .script else { return try await call() }
        try await run(change, machineID: machineID, of: holder, onRollback: onRollback, call)
    }

    private struct Shown: Decodable {
        var pendingChange: CloudMachine.Status?
        var pendingMutationID: UUID?
    }

    private struct Answer: Decodable {
        var state: JSONValue
        var shown: Shown?
        var rolledBack: Bool?
        var record: CloudMachine?
    }

    private struct Begin: Encodable {
        var state: JSONValue, machine: String, id: String, change: CloudMachine.Status, baseline: CloudMachine?
    }

    private struct Step: Encodable { var state: JSONValue, machine: String, id: String = "" }

    /// One step of the overlay in Rust; its answer's state becomes this one's.
    private func changes<Request: Encodable>(_ operation: String, _ request: Request, as: Answer.Type) -> Answer? {
        guard let answer = CloudMachineRules().call(operation, request, as: Answer.self) else { return nil }
        state = answer.state
        return answer
    }

    private func show(_ shown: Shown?, on holder: (any CloudMachineHolder)?) {
        guard let shown else { return }
        holder?.machine.pendingChange = shown.pendingChange
        holder?.machine.pendingMutationID = shown.pendingMutationID
    }

    /// Records a read ticket before its request is sent. A mutation remembers this boundary,
    /// so a response from before the mutation cannot clear its optimistic overlay.
    public func readIssued(_ read: Int) {
        struct Request: Encodable { var state: JSONValue, read: Int }
        _ = changes("cloud_machine_changes_read_issued", Request(state: state, read: read), as: Answer.self)
    }

    /// The newest pending operation drives presentation; older operations remain tracked until
    /// their own terminal record arrives. A failed newer request exposes the older operation.
    public func applyingPending(to record: CloudMachine, read: Int? = nil) -> CloudMachine {
        struct Request: Encodable { var state: JSONValue, record: CloudMachine, read: Int? }
        return changes("cloud_machine_changes_apply", Request(state: state, record: record, read: read), as: Answer.self)?.record ?? record
    }

    public func pendingStatus(for record: CloudMachine) -> CloudMachine.Status? {
        applyingPending(to: record).pendingChange
    }

    /// A list omitted a machine (including an authoritative delete confirmation).
    public func removed(_ machineID: String) {
        _ = changes("cloud_machine_changes_removed", Step(state: state, machine: machineID), as: Answer.self)
    }

    /// A change sent from here: a read already in flight cannot settle this newer operation.
    public func began(_ refresh: @escaping @MainActor () async -> Void) {
        guard !stopped, !Task.isCancelled else { return }
        cancelRead()
        pending = true
        pendingMachines = nil
        delay = Self.settleDelay
        schedule(refresh)
    }

    /// A change of `machineID` sent from here: like ``began(_:)``, but a machine whose record is pushed needs no read.
    public func began(machineID: String, _ refresh: @escaping @MainActor () async -> Void) {
        guard !isPushed(machineID) else { return }
        began(refresh)
        pendingMachines = [machineID]
    }

    private func pushWentLive() {
        guard pending, let machines = pendingMachines, !machines.contains(where: { !isPushed($0) }) else { return }
        pending = false
        cancelRead()
    }

    /// After each successful machine list: retain reads only while a machine is changing.
    public func listed(_ list: [CloudMachine], refresh: @escaping @MainActor () async -> Void) {
        // began/stop cancel the old task, including callbacks delivered from inside its refresh.
        guard !stopped, !Task.isCancelled else { return }
        listRevision += 1
        lastRefresh = refresh
        watched = list.filter { $0.status != .destroyed }
        // The daemon closes the socket of a machine this list no longer watches without a `lost`: it is not pushed now.
        live.formIntersection(watched.map(\.id))
        send(watched)
        // CloudService already reconciled these records with their read tickets. Replaying
        // settlement here without tickets could let a rejected stale response clear a mutation.
        delay = Self.settleDelay
        // A machine whose record is pushed settles from its push, not from a read.
        struct Request: Encodable { var state: JSONValue, list: [CloudMachine], pushed: [String] }
        struct Reply: Decodable { var machines: [String] }
        let pushed = list.map(\.id).filter(isPushed)
        let unsettled = Set(CloudMachineRules().call("cloud_machine_changes_unsettled", Request(state: state, list: list, pushed: pushed),
                                                     as: Reply.self)?.machines ?? list.filter(\.status.isChanging).map(\.id))
        pending = !unsettled.isEmpty
        pendingMachines = unsettled
        guard pending else {
            cancelRead()
            return
        }
        schedule(refresh)
    }

    public func stop() {
        watched = []
        live = []
        send([], superseding: true)
        lastRefresh = nil
        pendingMachines = nil
        stopped = true
        pending = false
        state = .object([:])
        delay = Self.settleDelay
        cancelRead()
    }

    private func cancelRead() {
        lifecycle += 1
        settle?.cancel()
        settle = nil
    }

    /// The wait before the next settle read (cmux-cloud-machine `changes::next_delay`).
    private static func nextDelay(_ delay: Duration, listed: Bool) -> Duration {
        struct Request: Encodable { var delayMs: Int, listed: Bool }
        struct Reply: Decodable { var delayMs: Int }
        let milliseconds = Int(delay.components.seconds * 1000 + delay.components.attoseconds / 1_000_000_000_000_000)
        let reply = CloudMachineRules().call("cloud_machine_changes_next_delay", Request(delayMs: milliseconds, listed: listed), as: Reply.self)
        return reply.map { .milliseconds($0.delayMs) } ?? settleDelay
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
            delay = Self.nextDelay(delay, listed: listRevision != revision)
            schedule(refresh)
        }
    }
}

extension CloudAPIClient {
    /// Names machines to the local daemon, which holds their state sockets at `baseURL` (``CloudConfiguration/relayAPIBaseURL(environment:)``,
    /// the platform origin) as this client's person and team; nil for the classic client, whose Stack session the platform does not take.
    @MainActor
    public func stateWatch(baseURL: URL, connection: @escaping @MainActor () -> DaemonConnection?) -> (@MainActor ([CloudMachine]) async -> Void)? {
        guard !sendsStackSession else { return nil }
        let teamID = teamID
        return { machines in
            // The crate reads timestamps in epoch milliseconds (CloudMachineRules).
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            guard let connection = connection(), let data = try? encoder.encode(machines),
                  let list = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
            let team = await teamID()
            _ = try? await connection.request(AppsMachineStateWatchRequest(machines: list, platform: baseURL.absoluteString, team: team))
        }
    }
}
