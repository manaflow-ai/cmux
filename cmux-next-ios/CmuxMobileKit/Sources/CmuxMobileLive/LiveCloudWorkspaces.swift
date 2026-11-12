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

    /// How often the list is read while nothing changes, and while a machine is changing.
    static let idlePoll: Duration = .seconds(60)
    static let busyPoll: Duration = .seconds(4)
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
    }

    /// Whether this serves `coordinator` (the shell makes one per signed-in session).
    public func isAttached(to coordinator: LiveCoordinator) -> Bool { self.coordinator === coordinator }

    /// Signed in: reads the list now and keeps it current.
    public func start() {
        guard pollTask == nil else { return }
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
        pollTask?.cancel()
        pollTask = nil
        for task in creationTasks.values { task.cancel() }
        creationTasks = [:]
        creations = []
        coordinator?.applyCloudMachines([])
    }

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

    private var pollInterval: Duration {
        let busy = !creations.isEmpty || model.machines.contains { $0.status.isTransition }
        return busy ? Self.busyPoll : Self.idlePoll
    }

    /// Reads `cloud.machine.list` and shows it. A failed read (offline, Cloud turned off,
    /// signed out) lists nothing new: a list never read lists no machine at all.
    public func refresh() async {
        await model.load()
        publish()
    }

    /// The list as machines on the Workspaces list, with this phone's pending creations.
    func publish() {
        guard let coordinator else { return }
        var machines: [MacDevice] = []
        let loaded: Bool = if case .failed = model.phase { false } else { true }
        if loaded {
            for machine in model.machines {
                let pending = creations.contains { $0.machineID == machine.id }
                machines.append(Self.device(machine, pending: pending))
            }
        }
        for creation in creations where creation.machineID == nil || !machines.contains(where: { $0.id == creation.machineID }) {
            machines.append(MacDevice(cloudMachine: creation.machineID ?? creation.id, name: creation.name,
                                      state: CloudMachineState(status: .provisioning, pendingWorkspace: true)))
        }
        coordinator.applyCloudMachines(machines)
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
        if coordinator.isCloudRefused(machineID), model.machine(machineID)?.status == .running {
            coordinator.retryCloud(machineID)
            return
        }
        guard let machine = model.machine(machineID), machine.status == .paused || machine.status == .failed else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.model.start(machine)
            self.publish()
            self.takeRefusal()
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
        let before = Set(model.machines.map(\.id))
        await model.create(name: creation.name, memoryMB: nil)
        if let refusal = takeRefusal(report: false) { return fail(creation, refusal) }
        guard let made = model.machines.first(where: { !before.contains($0.id) && $0.title == creation.name })
            ?? model.machines.first(where: { !before.contains($0.id) }) else {
            return fail(creation, String(localized: "The new Cloud machine didn't appear. Try again."))
        }
        update(creation.id) { $0.machineID = made.id }
        publish()
        // Running: the list is read until it says so (the service has no push for it).
        let deadline = ContinuousClock.now + Self.startBudget
        while model.machine(made.id)?.status != .running {
            if Task.isCancelled { return }
            if let status = model.machine(made.id)?.status, status == .failed || status == .deleting || status == .paused {
                return fail(creation, model.machine(made.id)?.note ?? String(localized: "\(creation.name) didn't start."))
            }
            guard ContinuousClock.now < deadline else {
                return fail(creation, String(localized: "\(creation.name) is taking long to start. It shows in the list once it runs."))
            }
            do { try await clock.sleep(for: Self.busyPoll) } catch { return }
            await model.load()
            publish()
        }
        publish()
        // Its carrier and daemon: the coordinator dials it as shown; Observation wakes this.
        coordinator?.touch(made.id)
        let ready = await ObservationWait({ [weak self] in self?.coordinator?.cloudDaemonReady(made.id) ?? false },
                                          clock: clock, budget: Self.daemonBudget).value
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

    private func fail(_ creation: Creation, _ message: String) {
        log.error("new cloud workspace failed: \(message, privacy: .public)")
        creations.removeAll { $0.id == creation.id }
        publish()
        onRefusal?(message)
    }

    /// The model's last refusal or approval note, taken so the Cloud Machines page doesn't show
    /// it again; reported to `onRefusal` unless the caller reports it itself.
    @discardableResult
    private func takeRefusal(report: Bool = true) -> String? {
        let message = model.failure ?? model.notice
        model.failure = nil
        model.notice = nil
        if report, let message { onRefusal?(message) }
        return message
    }
}
#endif
