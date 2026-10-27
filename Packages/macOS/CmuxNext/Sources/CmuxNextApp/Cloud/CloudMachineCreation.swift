import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Observation

/// One New Cloud Workspace (or New Cloud Machine) from the click to its open
/// terminal (cx-lu8f). It exists before any request goes out, so the window
/// shows it and the sidebar lists its row at once; its stage comes from the
/// create call, then from its machine's session (`CloudMachineStageInput`).
@Observable
final class CloudMachineCreation: Identifiable {
    let id = UUID()
    /// The window that shows it (nil: no window asked, e.g. the CLI).
    let windowID: String?
    /// The sidebar row id while it has no workspace: never a daemon id.
    var rowID: String { Self.rowPrefix + id.uuidString.lowercased() }
    static let rowPrefix = "cloud-creation:"
    /// When this attempt started (the click, or the last Retry).
    private(set) var startedAt: ContinuousClock.Instant
    /// The create call's phase; `created` once the machine exists (or for
    /// an existing machine that is not connected yet).
    private(set) var phase: CloudCreationPhase
    /// The machine's session once the server returned it.
    private(set) var session: CloudMachineSession?
    /// The workspace that opened when the machine was ready.
    private(set) var workspaceID: String?
    /// The paid plan the last failure needs, for a CLI or agent caller's answer.
    private(set) var planRefusal: ProRefusal?
    /// Time from the attempt's start to `ready`.
    private(set) var readyAfter: Duration?
    /// How the requested bootstrap started (``CloudMachineRequest/script``); nil without one.
    private(set) var bootstrap: CloudMachineBootstrap.Outcome?
    /// How the started bootstrap ended (`CloudMachineBootstrap.waitForCompletion(on:)`): nil until the
    /// bootstrap finishes; if ``isTornDown`` turns true first, it never will. The New Cloud Workspace wizard
    /// observes both, to open the clone at `repoPath` or stop waiting.
    private(set) var bootstrapCompletion: CloudMachineBootstrap.Completion?
    /// The wait behind ``bootstrapCompletion``. Its own task, not a child of ``task``: the row's normal
    /// removal (the workspace is mirrored) cancels ``task`` and must not end this wait. It ends with its
    /// bound, a new start (Retry), ``tearDown()`` or the creation's release (it holds the creation weakly).
    @ObservationIgnored private(set) var completionTask: Task<Void, Never>?
    /// The bootstrap start in flight (``beginBootstrapAttempt()``): a start that returns after a newer one
    /// began (a Retry while it was out on the machine) changes nothing.
    @ObservationIgnored private var bootstrapAttempt = 0
    /// ``tearDown()`` ran: the bootstrap wait stopped, and a start that returns after it (its flow was
    /// cancelled mid-start) starts none. Observed: a caller waiting on ``bootstrapCompletion`` stops on it.
    private(set) var isTornDown = false
    /// How the requested machine config's apply started (``CloudMachineRequest/machineConfig``).
    private(set) var machineConfig: CloudMachineBootstrap.Outcome?
    /// The flow's work for this creation; cancelled on dismiss and retry.
    @ObservationIgnored var task: Task<Void, Never>?
    /// What `cloud new-machine` asked for (size, idle pause); a Retry asks for the same, with
    /// the same idempotency key.
    private(set) var request: CloudMachineRequest

    /// The create went to the server once, to `team`: a Retry may find the machine it made, and
    /// goes to that same team.
    func markRequestSent(team: String?) {
        if !request.wasSent { request.team = team }
        request.wasSent = true
    }

    init(windowID: String?, session: CloudMachineSession? = nil, request: CloudMachineRequest = CloudMachineRequest(),
         clock: ContinuousClock = ContinuousClock()) {
        self.windowID = windowID
        self.session = session
        self.request = request
        phase = session == nil ? .requesting : .created
        startedAt = clock.now
    }

    var stageInput: CloudMachineStageInput {
        var input = session?.stageInput ?? CloudMachineStageInput()
        input.creation = phase
        return input
    }

    var stage: CloudMachineStage { stageInput.stage }

    /// The machine's sidebar name: its title once it exists.
    var machineTitle: String? { session?.machine.title }

    /// Time since the attempt started, or until it was ready.
    func elapsed(now: ContinuousClock.Instant = ContinuousClock().now) -> Duration {
        readyAfter ?? startedAt.duration(to: now)
    }

    func note(_ phase: CloudCreationPhase) {
        self.phase = phase
    }

    func attach(_ session: CloudMachineSession) {
        self.session = session
        phase = .created
    }

    func noteBootstrap(_ outcome: CloudMachineBootstrap.Outcome) {
        bootstrap = outcome
    }

    /// What a create refused for a paid plan tells the person: the server's text, its
    /// upgrade link, and the plan that lifts it (`pro` or `max`).
    struct ProRefusal: Equatable, Sendable {
        var message: String?
        var upgradeURL: URL?
        var plan = "pro"
        /// The app already showed its own upgrade card (the plan gate): no second offer.
        var offered = false
    }

    /// A create a paid plan would allow: the legacy `/api/vm` refusal that names one
    /// (``CloudAPIError/planRequired(message:upgradeURL:plan:)``), the app's own free-plan gate,
    /// or the app server's `plan_required`.
    nonisolated static func proRefusal(_ error: any Error) -> ProRefusal? {
        if case let CloudAPIError.planRequired(message, url, plan) = error { return ProRefusal(message: message, upgradeURL: url, plan: plan) }
        // The plan gate refused a free plan before any request: its card already offered an upgrade.
        if case CloudMachineCreateFlow.Failure.upgradeRequired(.freePlan) = error { return ProRefusal(plan: "pro", offered: true) }
        guard let failure = error as? CloudAppOpFailure, failure.code == CloudAppOpFailure.planRequired else { return nil }
        // The app server's message is the backend's English text, not the person's language: the dialog's own copy stands in.
        let plan = failure.details?["plan"]?.stringValue == "max" ? "max" : "pro"
        return ProRefusal(message: nil, upgradeURL: nil, plan: plan)
    }

    func noteBootstrapCompletion(_ completion: CloudMachineBootstrap.Completion) {
        bootstrapCompletion = completion
    }

    /// Waits for the run a start began (`wait`, which reads the machine) in a task of its own; a start
    /// that failed ends at once with its reason (a Retry starts it again).
    /// A new bootstrap start: the last one's wait stops and its completion goes, before the start is sent.
    func beginBootstrapAttempt() -> Int {
        completionTask?.cancel()
        completionTask = nil
        bootstrapCompletion = nil
        bootstrapAttempt += 1
        return bootstrapAttempt
    }

    /// `attempt` is the start's ``beginBootstrapAttempt()``; an older one's outcome is dropped.
    func awaitBootstrapCompletion(_ outcome: CloudMachineBootstrap.Outcome, attempt: Int,
                                  wait: @escaping @Sendable () async -> CloudMachineBootstrap.Completion) {
        guard !isTornDown, attempt == bootstrapAttempt else { return }
        noteBootstrap(outcome)
        guard outcome.status != "failed" else {
            bootstrapCompletion = .failed(reason: CloudStrings.bootstrapStartFailed(outcome.reason ?? ""))
            return
        }
        // task-owner: the creation (completionTask); cancelled by a new start, tearDown() or deinit
        completionTask = Task { [weak self] in
            let completion = await wait()
            guard !Task.isCancelled else { return }
            self?.noteBootstrapCompletion(completion)
        }
    }

    /// The creation ends for good (dismissed, or its machine deleted): its work stops, the
    /// bootstrap wait too.
    func tearDown() {
        isTornDown = true
        task?.cancel()
        completionTask?.cancel()
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // A task handle cancels from any thread.
    nonisolated deinit {
        completionTask?.cancel()
    }

    func noteMachineConfig(_ outcome: CloudMachineBootstrap.Outcome) {
        machineConfig = outcome
    }

    func fail(_ error: any Error) {
        // Before the phase: a caller that observes the failure reads the plan with it.
        planRefusal = Self.proRefusal(error)
        phase = .failed(CloudStrings.errorText(error))
    }

    func markReady(now: ContinuousClock.Instant = ContinuousClock().now) {
        if readyAfter == nil { readyAfter = startedAt.duration(to: now) }
    }

    func opened(_ workspaceID: String) {
        self.workspaceID = workspaceID
    }

    /// A new attempt (Retry): the clock starts again.
    func restart(now: ContinuousClock.Instant = ContinuousClock().now) {
        startedAt = now
        readyAfter = nil
        planRefusal = nil
        if session == nil { phase = .requesting }
    }
}

/// The creations in flight (`CloudService.creations`), for every window's
/// progress view and sidebar row.
@Observable
final class CloudCreations {
    private(set) var all: [CloudMachineCreation] = []

    /// A new creation, listed at once.
    @discardableResult
    func begin(window: String?, session: CloudMachineSession? = nil, request: CloudMachineRequest = CloudMachineRequest()) -> CloudMachineCreation {
        let creation = CloudMachineCreation(windowID: window, session: session, request: request)
        all.append(creation)
        return creation
    }

    func creation(_ id: UUID) -> CloudMachineCreation? { all.first { $0.id == id } }

    func creation(row: String) -> CloudMachineCreation? {
        guard row.hasPrefix(CloudMachineCreation.rowPrefix) else { return nil }
        return all.first { $0.rowID == row }
    }

    /// Whether `workspaceID` is the opened workspace of the creation `state`
    /// shows: showing it keeps the creation view until it is mirrored.
    func opens(_ workspaceID: String?, shownIn state: WindowState) -> Bool {
        guard let workspaceID, let shown = state.cloudCreation else { return false }
        return creation(shown)?.workspaceID == workspaceID
    }

    /// The creations window `id` lists, oldest first.
    func shown(in id: String) -> [CloudMachineCreation] { all.filter { $0.windowID == id } }

    /// The row leaves (its workspace is mirrored, or the person declined): the flow's task stops, and
    /// a bootstrap wait goes on for whoever still holds the creation (the wizard waits for its clone).
    func remove(_ creation: CloudMachineCreation) {
        creation.task?.cancel()
        all.removeAll { $0 === creation }
    }

    /// The creation ends for good: the row leaves and every wait of it stops.
    func end(_ creation: CloudMachineCreation) {
        creation.tearDown()
        remove(creation)
    }

    /// The machine was deleted or left the list: its creation ends.
    func machineRemoved(_ machineID: String) {
        for creation in all where creation.session?.machineID == machineID { end(creation) }
    }
}

/// Runs a creation: create the machine (unless it exists), wait for its
/// daemon's real ready event, open its first workspace, then hand that
/// workspace to the window. Every wait is an observation of state; nothing
/// sleeps. A failure stays shown with its reason until Retry or Dismiss.
struct CloudCreationFlow {
    let creations: CloudCreations
    /// Creates the machine; calls `note(.creating)` when the request is sent.
    let create: @MainActor (CloudMachineCreation) async throws -> CloudMachineSession
    /// The machine's first workspace (created when it has none).
    let open: @MainActor (CloudMachineSession) async throws -> String
    /// Places the opened workspace (`creation.workspaceID`) in its window.
    let show: @MainActor (String, CloudMachineCreation) -> Void
    /// A refusal a paid plan lifts (``CloudMachineCreation/proRefusal(_:)``): offers that plan.
    var planRequired: @MainActor (CloudMachineCreation.ProRefusal) -> Void = { _ in }

    /// Starts the requested bootstrap (``CloudMachineRequest/script``), then applies the requested
    /// machine config (``CloudMachineRequest/machineConfig``), each only while ``needsScript`` or
    /// ``needsMachineConfig`` says so, noting the outcomes on the creation. A run calls it after the
    /// create, and a Retry calls it again while either has not started (``needsBootstrap``), so a
    /// failed start is tried again with the machine.
    var bootstrap: @MainActor (CloudMachineCreation, CloudMachineSession) async -> Void = { _, _ in }

    /// A requested bootstrap script that has not started on the machine yet, or whose start failed.
    static func needsScript(_ creation: CloudMachineCreation) -> Bool {
        creation.request.script != nil && (creation.bootstrap.map { $0.status == "failed" } ?? true)
    }

    /// A requested machine config whose apply has not started yet, or whose start failed.
    static func needsMachineConfig(_ creation: CloudMachineCreation) -> Bool {
        creation.request.machineConfig != nil && (creation.machineConfig.map { $0.status == "failed" } ?? true)
    }

    /// Either of the above: the ``bootstrap`` hook has work left.
    static func needsBootstrap(_ creation: CloudMachineCreation) -> Bool { needsScript(creation) || needsMachineConfig(creation) }

    /// The ``bootstrap`` hook's work on `machine`: starts the requested bootstrap and, in the creation's own
    /// task (``CloudMachineCreation/awaitBootstrapCompletion(_:attempt:wait:)``), waits for its end without holding
    /// up the open; then applies the requested machine config. The first workspace still opens at the
    /// machine's default folder: a caller that wants the clone opens its own at the completion's `repoPath`.
    static func startBootstrap(_ creation: CloudMachineCreation, on machine: CloudMachineBootstrap.Machine) async {
        if let script = creation.request.script, needsScript(creation) {
            let attempt = creation.beginBootstrapAttempt()
            let outcome = await script.start(name: creation.request.name, on: machine)
            creation.awaitBootstrapCompletion(outcome, attempt: attempt) { await script.waitForCompletion(on: machine) }
        }
        // A flow cancelled (Retry, Dismiss) while the start was out applies nothing: its Retry applies it.
        guard !Task.isCancelled, !creation.isTornDown else { return }
        // After the bootstrap's start: the applier waits for its lock, so a --repo clone is there first.
        if let config = creation.request.machineConfig, needsMachineConfig(creation) {
            creation.noteMachineConfig(await config.apply(on: machine))
        }
    }

    /// Starts a creation and, when a window asked, shows it there at once
    /// (before any await): the click focuses the new work, not the old one.
    @discardableResult
    func start(in window: WindowState?, existing: CloudMachineSession?, request: CloudMachineRequest = CloudMachineRequest()) -> CloudMachineCreation {
        let creation = creations.begin(window: window?.id, session: existing, request: request)
        if let window {
            window.page = nil
            window.cloudCreation = creation.id
        }
        run(creation)
        return creation
    }

    func retry(_ creation: CloudMachineCreation) {
        creation.task?.cancel()
        creation.restart()
        creation.session?.retry()
        run(creation)
    }

    /// Dismiss (a failed creation): the row and the view go; a created
    /// machine stays in the sidebar with its own status.
    func dismiss(_ creation: CloudMachineCreation, in window: WindowState?) {
        creations.end(creation)
        if let window, window.cloudCreation == creation.id { window.cloudCreation = nil }
    }

    private func run(_ creation: CloudMachineCreation) {
        let create = create, open = open, show = show, bootstrap = bootstrap, creations = creations, planRequired = planRequired
        // task-owner: the creation's one run; cancelled by retry, dismiss or machine removal
        creation.task = Task { @MainActor in
            do {
                let session: CloudMachineSession
                if let existing = creation.session {
                    session = existing
                    if Self.needsBootstrap(creation) {
                        await bootstrap(creation, session)
                        try Task.checkCancellation()
                    }
                } else {
                    session = try await create(creation)
                    try Task.checkCancellation()
                    // Before attach: a caller waiting for the machine reads the bootstrap's outcome with it.
                    if Self.needsBootstrap(creation) {
                        await bootstrap(creation, session)
                        try Task.checkCancellation()
                    }
                    creation.attach(session)
                }
                guard await Self.ready(creation) else { return }
                creation.markReady()
                let id = try await open(session)
                try Task.checkCancellation()
                creation.opened(id)
                show(id, creation)
                // The row leaves when the workspace's own row can take its place.
                guard await Self.mirrored(id, on: session) else { return }
                creations.remove(creation)
            } catch is CancellationError {
                return
            } catch CloudMachineCreateFlow.Failure.declined {
                // The person said no in the confirmation: the creation closes
                // quietly (its window shows what it showed before).
                creations.remove(creation)
            } catch {
                guard !Task.isCancelled else { return }
                creation.fail(error)
                if let refusal = creation.planRefusal { planRequired(refusal) }
            }
        }
    }

    /// Waits for the ready stage (a failure in between may recover: the
    /// daemon keeps retrying). False when cancelled.
    private static func ready(_ creation: CloudMachineCreation) async -> Bool {
        for await stage in ObservationStream({ creation.stage }) where stage == .ready { return true }
        return false
    }

    private static func mirrored(_ id: String, on session: CloudMachineSession) async -> Bool {
        let store = session.daemon.store
        for await known in ObservationStream({ store.workspaces.contains { $0.id == id } }) where known { return true }
        return false
    }
}

extension CloudMachineBootstrap {
    /// The end of the run a start began, in words a person reads: the New Cloud Workspace wizard opens
    /// its project at `finished`'s `repoPath`, or shows `failed`'s reason. Blocks on the machine's runner
    /// (``waitForRun(on:bound:)``), never on a timer.
    func waitForCompletion(on machine: Machine) async -> Completion {
        Self.completion(await waitForRun(on: machine))
    }

    static func completion(_ run: Run) -> Completion {
        switch run {
        case let .finished(repoPath): .finished(repoPath: repoPath)
        case let .needsGitHub(repo): .failed(reason: CloudStrings.bootstrapNeedsGitHub(repo))
        case let .repoFailed(repo): .failed(reason: CloudStrings.bootstrapRepoFailed(repo, log: logPath))
        case let .scriptFailed(code): .failed(reason: CloudStrings.bootstrapScriptFailed(code, log: logPath))
        case .runnerNeverCame: .failed(reason: CloudStrings.bootstrapRunnerNeverCame)
        case .stopped: .failed(reason: CloudStrings.bootstrapStopped(log: logPath))
        case .stillRunning: .failed(reason: CloudStrings.bootstrapStillRunning(log: logPath))
        case let .unreachable(error): .failed(reason: CloudStrings.bootstrapUnreachable(error))
        }
    }
}
