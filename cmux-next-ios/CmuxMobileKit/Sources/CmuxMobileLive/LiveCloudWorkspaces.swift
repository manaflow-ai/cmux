#if os(iOS)
import CmuxMobileChief
import CmuxMobileModel
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "cloud")

/// The account's Cloud machines on the Workspaces list: reads `cloud.machine.list` with the
/// person's own token (the Cloud Machines page's model, shared with that page), hands the
/// machines to the coordinator (which dials the running ones over their carriers), and runs
/// the list's Cloud actions: Start, Retry and New Cloud Workspace.
@MainActor
@Observable
public final class LiveCloudWorkspaces: CloudWorkspaceActions {
    /// The Cloud Machines page's model: the same list and actions.
    public let model: CloudMachinesModel
    /// New Cloud Workspace creations in flight: their machines' lines say "Starting <name>…".
    public private(set) var creations: [Creation] = []
    /// A refusal to show (quota, plan, spending cap, a machine that didn't start).
    @ObservationIgnored public var onRefusal: (@MainActor (String) -> Void)?
    /// Makes the workspace on a running machine (the shell's `WorkspaceCreator.create`).
    @ObservationIgnored public var createWorkspace: (@MainActor (String) -> Workspace?)?

    @ObservationIgnored private weak var coordinator: LiveCoordinator?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var creationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var newID: () -> String = { UUID().uuidString.prefix(8).lowercased() }
    /// How often New Cloud Workspace reads the list while its machine starts (tests shorten it).
    @ObservationIgnored var busyPoll: Duration = LiveCloudWorkspaces.busyPoll

    /// How often the list is read while nothing changes, and while a machine is changing.
    nonisolated static let idlePoll: Duration = .seconds(60)
    nonisolated static let busyPoll: Duration = .seconds(4)
    /// How long New Cloud Workspace waits for its machine to run, then for its daemon.
    static let startBudget: Duration = .seconds(300)
    static let daemonBudget: Duration = .seconds(60)
    /// The name a new machine gets ("Cloud Machine", "Cloud Machine 2", …).
    public static let newMachineName = "Cloud Machine"

    /// One New Cloud Workspace: its pending line until the machine runs, then until the
    /// workspace on it exists.
    public struct Creation: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// The machine once the service made it (nil: still being asked for).
        public var machineID: String?
    }

    public init(model: CloudMachinesModel, coordinator: LiveCoordinator, clock: any Clock<Duration> = ContinuousClock()) {
        self.model = model
        self.coordinator = coordinator
        self.clock = clock
        coordinator.onCloudRefusal = { [weak self] _, _ in self?.refreshSoon() }
        // A carrier dropped: read the list now, so the machine is dialed again only if it still runs.
        coordinator.onCloudLinkDropped = { [weak self] _ in self?.refreshSoon() }
        // The network came back, or a held machine was opened: read now (only a read lifts a hold).
        coordinator.onCloudHoldsWaiting = { [weak self] restart in
            guard let self else { return }
            if restart || !self.readWillLiftHolds { self.refreshSoon() }
        }
        // The Cloud Machines page changed the shared list (a delete, a start): the Workspaces list follows now.
        model.onMachinesChanged = { [weak self] in self?.publish() }
    }

    /// Whether this serves `coordinator` (the shell makes one per signed-in session).
    public func isAttached(to coordinator: LiveCoordinator) -> Bool { self.coordinator === coordinator }

    /// Signed in: reads the list now and keeps it current.
    public func start() {
        guard pollTask == nil else { return }
        stopped = false
        let clock = clock
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Held only for the read: a model nobody keeps ends the loop.
                guard let interval = await self?.refreshed() else { return }
                do { try await clock.sleep(for: interval) } catch { return }
            }
        }
    }

    /// Signed out: nothing more is read, and no Cloud machine is listed.
    public func stop() {
        stopped = true
        stopGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        for task in creationTasks.values { task.cancel() }
        creationTasks = [:]
        for task in startTasks.values { task.cancel() }
        startTasks = [:]
        creations = []
        starting = []
        lastListed = nil
        coordinator?.applyCloudMachines([])
    }

    /// Stopped (signed out, or Cloud turned off): an action still in flight lists nothing again.
    @ObservationIgnored private var stopped = false
    /// Bumped by each stop: work begun before it never touches what came after.
    @ObservationIgnored private var stopGeneration = 0
    /// Starts in flight, by machine, so `stop` cancels them.
    @ObservationIgnored private var startTasks: [String: Task<Void, Never>] = [:]

    /// Back in the foreground, or after a refusal: read the list again now.
    public func refreshSoon() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        start()
    }

    private func refreshed() async -> Duration {
        await refresh()
        return pollInterval
    }

    /// The poll is the one reader of the list while anything changes (New Cloud Workspace waits
    /// on what it publishes): every `busyPoll`, then every `stuckPoll` once a change has run past
    /// `stuckAfter` (a machine that sticks in provisioning is not read every 4 s forever).
    private var pollInterval: Duration {
        // A held machine (its carrier dropped) is busy too: its hold waits for a good read, so a
        // read that failed (the outage itself) is tried again soon, not a minute later.
        let held = !(coordinator?.cloudDropHolds.isEmpty ?? true)
        let busy = held || !creations.isEmpty || !starting.isEmpty || model.machines.contains { $0.status.isTransition }
        if busy, busySince == nil { busySince = .now }
        if !busy { busySince = nil }
        return Self.pollInterval(busy: busy, busyFor: busySince.map { .now - $0 }, busyPoll: busyPoll)
    }

    nonisolated static let stuckAfter: Duration = .seconds(120)
    nonisolated static let stuckPoll: Duration = .seconds(15)

    nonisolated static func pollInterval(busy: Bool, busyFor: Duration?, busyPoll: Duration = LiveCloudWorkspaces.busyPoll) -> Duration {
        guard busy else { return idlePoll }
        return (busyFor ?? .zero) >= stuckAfter ? stuckPoll : busyPoll
    }

    /// When the current run of changes began (nil: nothing changing).
    @ObservationIgnored private var busySince: ContinuousClock.Instant?
    /// Machines this phone asked to start, shown waking until the op answers.
    @ObservationIgnored private var starting: Set<String> = []

    /// Reads `cloud.machine.list` and shows it. A failed read (offline, a token being
    /// refreshed, the service briefly away) changes nothing on screen: the last list stays, so
    /// no link or row goes for a transient failure. Only `stop` (sign-out) clears it.
    /// The stamp of the poll's read in flight (nil: none out).
    @ObservationIgnored private var readStampInFlight: Int?

    /// A read is out that began after every hold now placed, so its answer will lift them.
    private var readWillLiftHolds: Bool {
        guard let stamp = readStampInFlight, let coordinator else { return false }
        return coordinator.cloudDropHolds.values.allSatisfy { $0 <= stamp }
    }

    public func refresh() async {
        // Where the drop holds stand now: this read may lift only the holds placed before it.
        let stamp = coordinator?.cloudReadStamp
        readStampInFlight = stamp
        defer { if readStampInFlight == stamp { readStampInFlight = nil } }
        // The list only: the plan and snapshots are the Cloud Machines page's, read when it opens.
        let read = await model.loadMachines()
        // Only a read that answered, and was not cancelled, is fresh word on a machine.
        publish(fromRead: read && !Task.isCancelled, readStamp: stamp)
    }

    /// The machines of the last list that read (nil: none read yet).
    @ObservationIgnored private var lastListed: [CloudMachine]?

    /// The list as machines on the Workspaces list, with this phone's pending creations.
    func publish(fromRead: Bool = false, readStamp: Int? = nil) {
        guard !stopped, let coordinator else { return }
        var machines: [MacDevice] = []
        if case .failed = model.phase {} else { lastListed = model.machines }
        for var machine in lastListed ?? [] {
            if starting.contains(machine.id), machine.status == .paused || machine.status == .failed { machine.status = .starting }
            let pending = creations.contains { $0.machineID == machine.id }
            machines.append(Self.device(machine, pending: pending))
        }
        for creation in creations where creation.machineID == nil || !machines.contains(where: { $0.id == creation.machineID }) {
            machines.append(MacDevice(cloudMachine: creation.machineID ?? creation.id, name: creation.name,
                                      state: CloudMachineState(status: .provisioning, pendingWorkspace: true)))
        }
        // A failed or cancelled read is no fresh word on a machine: holds stay until one succeeds.
        coordinator.applyCloudMachines(machines, fromRead: fromRead, readStamp: readStamp)
    }

    /// One machine as the list shows it.
    nonisolated static func device(_ machine: CloudMachine, pending: Bool = false) -> MacDevice {
        let status = CloudMachineState.Status(rawValue: machine.status.rawValue) ?? .failed
        let note = status == .failed ? machine.note ?? String(localized: "It didn't start.") : machine.note
        return MacDevice(cloudMachine: machine.id, name: machine.title,
                         state: CloudMachineState(status: status, note: note, pendingWorkspace: pending && status != .running),
                         lastActiveAt: machine.lastActiveAt)
    }

    // MARK: CloudWorkspaceActions

    public var canCreateMachine: Bool {
        guard model.canAct, creations.isEmpty else { return false }
        if case .failed = model.phase { return false }
        return true
    }

    /// Start a paused machine; Retry a failed one (a carrier refusal dials again, a failed
    /// machine starts again).
    public func start(machineID: String) {
        guard let coordinator else { return }
        // This phone's own refusal (whatever the listing says now): dial again.
        if coordinator.isCloudRefused(machineID) {
            coordinator.retryCloud(machineID)
            return
        }
        guard let machine = model.machine(machineID), machine.status == .paused || machine.status == .failed,
              !starting.contains(machineID) else { return }
        // Waking at once on the list, before the op answers.
        starting.insert(machineID)
        publish()
        let generation = stopGeneration
        startTasks[machineID] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.model.start(machine)
            // A Start from before a stop (sign-out, then sign-in again) touches nothing of the new one.
            guard self.stopGeneration == generation, !self.stopped else { return }
            self.startTasks[machineID] = nil
            self.starting.remove(machineID)
            self.publish()
            self.report(outcome)
            self.refreshSoon()
        }
    }

    public func newCloudWorkspace(open: @escaping @MainActor (Workspace) -> Void) {
        guard canCreateMachine else { return }
        let titles = model.machines.map(\.title)
        let name = WorkspaceCreator.uniqueTitle(Self.newMachineName, existing: titles)
        let creation = Creation(id: "pending-cloud-\(newID())", name: name)
        creations.append(creation)
        publish()
        creationTasks[creation.id] = Task { [weak self] in
            await self?.run(creation, open: open)
            self?.creationTasks[creation.id] = nil
        }
    }

    /// The machine, then its running state, then its daemon, then the workspace. Any refusal
    /// takes the pending line away and says why.
    private func run(_ creation: Creation, open: @escaping @MainActor (Workspace) -> Void) async {
        // This create's own outcome: a list read failing meanwhile (which writes the page's
        // shared `failure`) never reads as a refusal of a machine that was made.
        let made: CloudMachine
        switch await model.create(name: creation.name, memoryMB: nil) {
        case .done(let answered):
            guard let machine = answered.first else {
                return fail(creation, String(localized: "The new Cloud machine didn't appear. Try again."))
            }
            made = machine
        case .refused(let message), .awaitingApproval(let message):
            clearShared(message)
            return fail(creation, message)
        case .busy:
            return fail(creation, String(localized: "Another Cloud machine change is still running. Try again in a moment."))
        case .signedOut:
            return fail(creation, String(localized: "Sign in to cmux to make a Cloud machine."))
        case .cancelled:
            return fail(creation, nil)
        }
        update(creation.id) { $0.machineID = made.id }
        publish()
        // The poll reads the list from now on (busy); this waits on what it publishes.
        refreshSoon()
        // Running: the poll reads the list (the one reader); this waits on what it reads.
        let id = made.id
        let settled = await ObservationWait({ [weak self] in
            guard let status = self?.model.machine(id)?.status else { return false }
            return status != .provisioning && status != .starting
        }, clock: clock, budget: Self.startBudget).value
        if Task.isCancelled { return }
        guard settled else {
            return fail(creation, String(localized: "\(creation.name) is taking long to start. It shows in the list once it runs."))
        }
        guard model.machine(id)?.status == .running else {
            return fail(creation, model.machine(id)?.note ?? String(localized: "\(creation.name) didn't start."))
        }
        publish()
        // Its carrier and daemon: the coordinator dials it as shown. The wait reads the store's
        // observed data phase (the daemon's list arrived), so Observation wakes it.
        coordinator?.touch(made.id)
        let ready = await ObservationWait({ [weak self] in
            guard let store = self?.coordinator?.store else { return false }
            let phase = store.macDataPhase(id)
            return phase == .live || phase == .empty
        }, clock: clock, budget: Self.daemonBudget).value && coordinator?.cloudDaemonReady(id) == true
        // Stopped (signed out) or cancelled while it waited: nothing to say or open.
        if Task.isCancelled || stopped { return }
        guard ready, let workspace = createWorkspace?(made.id) else {
            return fail(creation, String(localized: "\(creation.name) is running, but this iPhone couldn't reach it yet. Open it from the list."))
        }
        creations.removeAll { $0.id == creation.id }
        publish()
        open(workspace)
    }

    private func update(_ id: String, _ change: (inout Creation) -> Void) {
        guard let index = creations.firstIndex(where: { $0.id == id }) else { return }
        change(&creations[index])
    }

    /// Ends a pending creation; `message` is said to the person (nil: cancelled, nothing to say).
    private func fail(_ creation: Creation, _ message: String?) {
        log.error("new cloud workspace failed: \(message ?? "cancelled", privacy: .public)")
        creations.removeAll { $0.id == creation.id }
        publish()
        if let message { onRefusal?(message) }
    }

    /// An action's own refusal or approval note, said once (the page's alert does not show it too).
    private func report(_ outcome: CloudMachinesModel.Outcome) {
        switch outcome {
        case .refused(let message), .awaitingApproval(let message):
            clearShared(message)
            onRefusal?(message)
        case .busy:
            onRefusal?(String(localized: "Another Cloud machine change is still running. Try again in a moment."))
        case .signedOut:
            onRefusal?(String(localized: "Sign in to cmux to change Cloud machines."))
        case .cancelled, .done:
            break
        }
    }

    /// The page's shared alert text, when it is this action's.
    private func clearShared(_ message: String) {
        if model.failure == message { model.failure = nil }
        if model.notice == message { model.notice = nil }
    }
}
#endif
