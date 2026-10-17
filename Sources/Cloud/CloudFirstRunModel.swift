import CmuxFoundation
import Foundation
import Observation

/// The "Start your first cloud agent" tour: one surface, three steps that run
/// side by side.
///
/// 1. Key: the chosen agent's key is found in Cloud Secrets, or the team's
///    model-router account runs it with no key at all; only when neither
///    exists does the step ask for one key.
/// 2. Machine: starts the moment the tour opens (a ready machine is reused,
///    else one is created through the shared create coordinator), so it is
///    usually up before the person has picked a repository.
/// 3. Repository and task: Go saves a typed key, waits for the machine if it
///    is still starting, and runs the same `cmux vm clone … --agent` every
///    other entrypoint runs, which opens the agent's terminal.
///
/// Every failure lands on its step with one reason and one recovery. The
/// timeline measures the tour from opening to a running agent and writes one
/// line to the local debug log; nothing is reported anywhere else.
@MainActor
@Observable
final class CloudFirstRunModel {
    /// The app seams. The presenter binds the live ones; tests inject fakes.
    struct Backend {
        /// Cloud Secrets names that reach a machine cloned into `projectKey`:
        /// every machine's plus that project's (`vm clone` links the machine to
        /// it). Names only.
        var vaultNames: @MainActor (_ projectKey: String?) -> Set<String>
        /// CodeRouter account types the team has active.
        var activeTeamProviders: @MainActor () -> Set<String>
        /// A ready machine to reuse, from a fleet read.
        var findReadyMachine: @MainActor () async -> CloudFirstRunMachine?
        /// Starts a new machine; false when it could not start at all.
        var createMachine: @MainActor (_ finished: @escaping @MainActor (Result<CloudFirstRunMachine, CloudFirstRunFailure>) -> Void) -> Bool
        /// Stores the typed key in Cloud Secrets for every machine.
        var saveKey: @MainActor (_ name: String, _ value: String) async throws -> Void
        /// Runs `cmux <arguments>`; false when the process could not start.
        var runClone: @MainActor (
            _ arguments: [String],
            _ onOutput: @escaping @MainActor (String) -> Void,
            _ finished: @escaping @MainActor (_ status: Int32, _ output: String) -> Void
        ) -> Bool
        /// Cancels the in-flight create this tour started (the coordinator
        /// deletes the machine if the provider already made it).
        var cancelCreate: @MainActor () -> Void = {}
        /// Deletes a machine through the app's shared delete path.
        var deleteMachine: @MainActor (_ machineID: String) -> Void = { _ in }
        var log: @MainActor (String) -> Void = { _ in }
        var now: @MainActor () -> Date = Date.init
    }

    enum Step: String, CaseIterable, Sendable {
        case key
        case machine
        case agent
    }

    enum StepState: Equatable {
        case waiting
        case working
        case done
        case failed(CloudFirstRunFailure)
    }

    enum MachineState: Equatable {
        case looking
        case starting
        case ready(CloudFirstRunMachine)
        case failed(CloudFirstRunFailure)
    }

    /// Where the machine came from. Only a machine the tour itself started
    /// is ever cleaned up; a reused one is never touched.
    enum MachineOrigin: Equatable {
        case none
        case reused
        case provisioning
        case provisioned(machineID: String)
    }

    /// What cancelling did about the tour's own machine.
    enum Cleanup: String, Equatable {
        case none
        /// The create was still running; it is cancelled, and a machine it
        /// still produces is deleted the moment its id arrives.
        case cancellingCreate = "cancelling_create"
        case deleted
    }

    enum RunState: Equatable {
        case editing
        case savingKey
        case waitingForMachine
        case cloning
        case started(CloudFirstRunCloneResult)
        case failed(CloudFirstRunFailure)

        var isBusy: Bool {
            switch self {
            case .savingKey, .waitingForMachine, .cloning: return true
            case .editing, .started, .failed: return false
            }
        }
    }

    var agent: CloudFirstRunAgent = .claude {
        didSet { resolveKey() }
    }
    var repoText = "" {
        didSet {
            // A key scoped to the chosen repository's project reaches the machine too.
            guard CloudFirstRunRepo.reference(oldValue)?.projectKey != repoReference?.projectKey else { return }
            refreshVaultNames()
        }
    }
    var prompt = CloudFirstRunRepo.defaultPrompt
    /// The key typed this run. Never logged, never in debug state; cleared
    /// once the vault holds it.
    var typedKey = "" {
        didSet { resolveKey() }
    }

    private(set) var keySource: CloudFirstRunKeySource = .missing
    private(set) var keyFailure: CloudFirstRunFailure?
    private(set) var machine: MachineState = .looking
    private(set) var run: RunState = .editing
    private(set) var origin: MachineOrigin = .none
    private(set) var lastCleanup: Cleanup = .none
    private(set) var progress = CloudFirstRunCloneProgress()
    private(set) var timeline: CloudFirstRunTimeline
    /// Bumped when the key field should take focus (Fix the Key).
    private(set) var keyFocusRequest = 0
    /// Called once when the agent's terminal is open.
    @ObservationIgnored var onStarted: ((CloudFirstRunCloneResult) -> Void)?

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private var vaultNames: Set<String> = []
    @ObservationIgnored private var teamProviders: Set<String> = []
    @ObservationIgnored private var pendingRepo: CloudOpenRepositoryReference?
    @ObservationIgnored private var hasStarted = false
    /// Bumped by every machine start and by cancel, so a lookup or create
    /// that finishes for an earlier start is recognized as stale.
    @ObservationIgnored private var machineGeneration = 0
    /// The fleet read in flight and the key save in flight; tests await them.
    @ObservationIgnored private(set) var machineTask: Task<Void, Never>?
    @ObservationIgnored private(set) var keyTask: Task<Void, Never>?

    init(backend: Backend) {
        self.backend = backend
        timeline = CloudFirstRunTimeline(openedAt: backend.now())
    }

    /// Begins the warm path. Idempotent: reopening a hidden tour keeps going.
    func start() {
        refreshKeys()
        guard !hasStarted else { return }
        hasStarted = true
        startMachine()
    }

    // MARK: Inputs

    var repoReference: CloudOpenRepositoryReference? { CloudFirstRunRepo.reference(repoText) }
    var repoDisplayName: String? { repoReference?.displayName }
    var isSampleRepo: Bool { repoReference?.cloneArgument == CloudFirstRunRepo.sample }

    func useSampleRepo() {
        repoText = CloudFirstRunRepo.sample
    }

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canGo: Bool {
        switch run {
        case .editing, .failed: break
        case .savingKey, .waitingForMachine, .cloning, .started: return false
        }
        return repoReference != nil
            && keySource.isReady
            && !trimmedPrompt.isEmpty
            && trimmedPrompt.count <= CloudFirstRunRepo.maxPromptLength
    }

    /// Re-reads vault names and team accounts (the presenter calls this when
    /// either changes).
    func refreshKeys() {
        teamProviders = backend.activeTeamProviders()
        refreshVaultNames()
    }

    private func refreshVaultNames() {
        vaultNames = backend.vaultNames(repoReference?.projectKey)
        resolveKey()
    }

    private func resolveKey() {
        keySource = CloudFirstRunKeySource.resolve(
            agent: agent,
            vaultNames: vaultNames,
            activeTeamProviders: teamProviders,
            typedKey: typedKey
        )
        switch keySource {
        case .vault, .teamRouter: timeline.record(.keyReady, at: backend.now())
        case .typed, .missing: break
        }
    }

    // MARK: Steps

    func state(of step: Step) -> StepState {
        switch step {
        case .key:
            if let keyFailure { return .failed(keyFailure) }
            switch keySource {
            case .vault, .teamRouter: return .done
            case .typed: return run == .savingKey ? .working : .waiting
            case .missing: return .waiting
            }
        case .machine:
            switch machine {
            case .looking, .starting: return .working
            case .ready: return .done
            case .failed(let failure): return .failed(failure)
            }
        case .agent:
            switch run {
            case .editing: return .waiting
            case .savingKey, .waitingForMachine, .cloning: return .working
            case .started: return .done
            case .failed(let failure):
                // A key or machine failure belongs to its own step.
                return keyFailure == nil && machineFailure == nil ? .failed(failure) : .waiting
            }
        }
    }

    private var machineFailure: CloudFirstRunFailure? {
        if case .failed(let failure) = machine { return failure }
        return nil
    }

    var readyMachine: CloudFirstRunMachine? {
        if case .ready(let machine) = machine { return machine }
        return nil
    }

    // MARK: Machine

    private func startMachine() {
        machineGeneration &+= 1
        let generation = machineGeneration
        machine = .looking
        origin = .none
        machineTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.backend.findReadyMachine()
            // Cancelled (or restarted) while the fleet read was out.
            guard generation == self.machineGeneration else { return }
            if let found {
                self.origin = .reused
                self.machineReady(found)
            } else {
                self.createMachine(generation: generation)
            }
        }
    }

    private func createMachine(generation: Int) {
        machine = .starting
        origin = .provisioning
        // Strong capture on purpose: the create's owner holds this callback
        // until the create ends, so a cancelled tour still deletes a machine
        // that arrives after the sheet is gone.
        let started = backend.createMachine { result in
            guard generation == self.machineGeneration else {
                if case .success(let created) = result {
                    self.backend.deleteMachine(created.id)
                    self.lastCleanup = .deleted
                    self.backend.log("cloud.firstRun.cleanup deleted=late")
                }
                return
            }
            switch result {
            case .success(let created):
                self.origin = .provisioned(machineID: created.id)
                self.machineReady(created)
            case .failure(let failure):
                self.origin = .none
                self.machineFailed(failure)
            }
        }
        if !started {
            origin = .none
            machineFailed(CloudFirstRunFailure(
                reason: String(
                    localized: "cloud.firstRun.machine.couldNotStart",
                    defaultValue: "cmux couldn\u{2019}t start a machine. Check that you\u{2019}re signed in."
                ),
                recovery: .retryMachine
            ))
        }
    }

    private func machineReady(_ ready: CloudFirstRunMachine) {
        machine = .ready(ready)
        timeline.record(.machineReady, at: backend.now())
        if run == .waitingForMachine, let repo = pendingRepo {
            launchClone(repo: repo, machine: ready)
        }
    }

    private func machineFailed(_ failure: CloudFirstRunFailure) {
        machine = .failed(failure)
        if run == .waitingForMachine { fail(failure) }
    }

    // MARK: Go

    func go() {
        guard canGo, let repo = repoReference else { return }
        timeline.record(.go, at: backend.now())
        timeline.clear(.failed)
        keyFailure = nil
        pendingRepo = repo
        if keySource == .typed {
            run = .savingKey
            let name = agent.savedKeyName
            let value = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            keyTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.backend.saveKey(name, value)
                } catch {
                    let failure = CloudFirstRunFailure(
                        reason: (error as? LocalizedError)?.errorDescription ?? String(
                            localized: "cloud.firstRun.key.saveFailed",
                            defaultValue: "The key couldn\u{2019}t be saved to Cloud Secrets."
                        ),
                        recovery: .editKey
                    )
                    self.keyFailure = failure
                    self.fail(failure)
                    return
                }
                self.typedKey = ""
                self.refreshKeys()
                self.timeline.record(.keyReady, at: self.backend.now())
                self.continueAfterKey(repo: repo)
            }
        } else {
            continueAfterKey(repo: repo)
        }
    }

    private func continueAfterKey(repo: CloudOpenRepositoryReference) {
        switch machine {
        case .ready(let ready):
            launchClone(repo: repo, machine: ready)
        case .failed:
            run = .waitingForMachine
            startMachine()
        case .looking, .starting:
            run = .waitingForMachine
        }
    }

    private func launchClone(repo: CloudOpenRepositoryReference, machine ready: CloudFirstRunMachine) {
        run = .cloning
        progress = CloudFirstRunCloneProgress()
        let arguments = CloudFirstRunCommand.cloneArguments(
            repo: repo, machineID: ready.id, agent: agent, prompt: trimmedPrompt
        )
        let launched = backend.runClone(arguments, { [weak self] chunk in
            self?.progress.consume(chunk)
        }, { [weak self] status, output in
            self?.cloneFinished(status: status, output: output)
        })
        if !launched {
            fail(CloudFirstRunFailure(
                reason: String(
                    localized: "cloud.firstRun.clone.couldNotStart",
                    defaultValue: "cmux couldn\u{2019}t run vm clone. Check that you\u{2019}re signed in."
                ),
                recovery: .retryClone
            ))
        }
    }

    private func cloneFinished(status: Int32, output: String) {
        let result = CloudFirstRunCloneResult.parse(output: output)
        if status == 0, let result, result.agentTerminalID != nil {
            run = .started(result)
            timeline.record(.agentStarted, at: backend.now())
            backend.log(timeline.logLine(cloneTimings: result.timings) + " outcome=started")
            onStarted?(result)
            return
        }
        if status == 0 {
            fail(CloudFirstRunFailure(
                reason: String(
                    localized: "cloud.firstRun.failure.noAgent",
                    defaultValue: "The repository is on the machine, but the agent didn\u{2019}t start."
                ),
                recovery: .retryClone
            ), cloneTimings: result?.timings ?? [:])
            return
        }
        fail(CloudFirstRunFailure.clone(output: output, status: status), cloneTimings: result?.timings ?? [:])
    }

    private func fail(_ failure: CloudFirstRunFailure, cloneTimings: [String: Double] = [:]) {
        run = .failed(failure)
        timeline.record(.failed, at: backend.now())
        // The recovery name only: the reason can quote CLI output.
        backend.log(timeline.logLine(cloneTimings: cloneTimings) + " outcome=failed recovery=\(failure.recovery.rawValue)")
    }

    // MARK: Recovery

    /// What a failed step's one button does. `addGitHubToken` belongs to the
    /// presenter (it opens Cloud Secrets) and returns false here.
    @discardableResult
    func perform(_ recovery: CloudFirstRunRecovery) -> Bool {
        switch recovery {
        case .retryMachine:
            // A Go that was waiting on this machine keeps waiting, so the
            // retry finishes the run without a second press.
            if case .failed = run {
                run = pendingRepo != nil && keyFailure == nil ? .waitingForMachine : .editing
                timeline.clear(.failed)
            }
            startMachine()
            return true
        case .retryClone:
            run = .editing
            go()
            return true
        case .editKey:
            keyFailure = nil
            run = .editing
            keyFocusRequest &+= 1
            return true
        case .addGitHubToken:
            run = .editing
            return false
        }
    }

    // MARK: Cancel

    /// Whether cancelling now deletes a machine this tour started: true until
    /// an agent runs on it.
    var cancelDeletesMachine: Bool {
        guard !timeline.isFinished else { return false }
        switch origin {
        case .provisioning, .provisioned: return true
        case .none, .reused: return false
        }
    }

    /// The person left before any agent ran (Cancel, Esc, or a detour out of
    /// the sheet before Go). A machine this tour started is deleted, or its
    /// create cancelled, since nothing was set up on it; a reused machine is
    /// left alone. Inputs stay, and ``start()`` starts the machine step
    /// again. Deleting rather than pausing: a paused machine costs nothing,
    /// but it would stay in the person's list as a machine they never asked
    /// for, and a never-used one holds nothing worth keeping. No-op once an agent has started or while a Go is running.
    func cancel() {
        // After Go the run owns the machine: closing then is Hide, not cancel.
        guard !timeline.isFinished, !run.isBusy else { return }
        switch origin {
        case .provisioned(let machineID):
            backend.deleteMachine(machineID)
            lastCleanup = .deleted
        case .provisioning:
            backend.cancelCreate()
            lastCleanup = .cancellingCreate
        case .none, .reused:
            lastCleanup = .none
        }
        machineGeneration &+= 1
        machineTask = nil
        origin = .none
        machine = .looking
        hasStarted = false
        run = .editing
        backend.log(timeline.logLine() + " outcome=cancelled cleanup=\(lastCleanup.rawValue)")
    }

    /// The recovery the surface shows now, wherever the failure sits.
    var currentFailure: CloudFirstRunFailure? {
        if let keyFailure { return keyFailure }
        if let machineFailure { return machineFailure }
        if case .failed(let failure) = run { return failure }
        return nil
    }
}
