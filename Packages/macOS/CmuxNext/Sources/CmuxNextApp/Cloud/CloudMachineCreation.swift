import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
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
    /// Time from the attempt's start to `ready`.
    private(set) var readyAfter: Duration?
    /// The flow's work for this creation, off main; cancelled on dismiss and retry.
    @ObservationIgnored var task: Task<Void, any Error>?
    /// The run that owns the creation's steps (bumped by each run: the first, and every Retry). A cancelled run's
    /// step already queued on main finds a newer attempt, or the creation unlisted, and changes nothing.
    @ObservationIgnored private(set) var attempt: UInt64 = 0

    init(windowID: String?, session: CloudMachineSession? = nil, clock: ContinuousClock = ContinuousClock()) {
        self.windowID = windowID
        self.session = session
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

    func fail(_ error: any Error) {
        phase = .failed(RefusalStrings.describe(error))
    }

    /// A new run owns the creation's steps from here on.
    func beginAttempt() -> UInt64 {
        attempt += 1
        return attempt
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
        if session == nil { phase = .requesting }
    }
}

/// The creations in flight (`CloudService.creations`), for every window's
/// progress view and sidebar row.
@Observable
final class CloudCreations {
    private(set) var all: [CloudMachineCreation] = []
    /// Where each creation's run is awaited (off main), and where its steps on the creation run.
    let work: BackgroundWork
    let mainWork: MainWorkScheduler

    init(work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.work = work
        self.mainWork = mainWork
    }

    /// A new creation, listed at once.
    @discardableResult
    func begin(window: String?, session: CloudMachineSession? = nil) -> CloudMachineCreation {
        let creation = CloudMachineCreation(windowID: window, session: session)
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

    /// Whether run `attempt` still owns `creation`: its latest run, and still listed (not removed or dismissed).
    func owns(_ attempt: UInt64, of creation: CloudMachineCreation) -> Bool {
        creation.attempt == attempt && all.contains { $0 === creation }
    }

    func remove(_ creation: CloudMachineCreation) {
        creation.task?.cancel()
        all.removeAll { $0 === creation }
    }

    /// The machine was deleted or left the list: its creation ends.
    func machineRemoved(_ machineID: String) {
        for creation in all where creation.session?.machineID == machineID { remove(creation) }
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

    /// Starts a creation and, when a window asked, shows it there at once
    /// (before any await): the click focuses the new work, not the old one.
    @discardableResult
    func start(in window: WindowState?, existing: CloudMachineSession?) -> CloudMachineCreation {
        let creation = creations.begin(window: window?.id, session: existing)
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
        creations.remove(creation)
        if let window, window.cloudCreation == creation.id { window.cloudCreation = nil }
    }

    private func run(_ creation: CloudMachineCreation) {
        let create = create, open = open, show = show, creations = creations
        let mainWork = creations.mainWork, existing = creation.session, attempt = creation.beginAttempt()
        // A detached task inherits no task local: the run carries the caller's action scopes, so the person's
        // New Cloud Workspace still owns the daemon commands of the create and the open, and the window's show.
        let scopes = ActionScopes.current
        // task-owner: the creation's one run; cancelled by retry, dismiss or machine removal. R-hop: the run is
        // awaited off main; each step on the creation and its window is one visible task (a person's New Cloud
        // Workspace, shown in the window that asked). A cancel can land between a step's check off main and its
        // queued body, so each body runs only while this run still owns the creation.
        creation.task = creations.work.task(.userVisible) {
            await scopes.awaiting {
                do {
                    let session: CloudMachineSession
                    if let existing {
                        session = existing
                    } else {
                        session = try await create(creation)
                        try Task.checkCancellation()
                        await mainWork.apply(.visible, owner: "CloudCreation.attach") {
                            guard creations.owns(attempt, of: creation) else { return }
                            creation.attach(session)
                        }
                    }
                    guard await Self.ready(creation, on: mainWork) else { return }
                    await mainWork.apply(.visible, owner: "CloudCreation.ready") {
                        guard creations.owns(attempt, of: creation) else { return }
                        creation.markReady()
                    }
                    let id = try await open(session)
                    try Task.checkCancellation()
                    await mainWork.apply(.visible, owner: "CloudCreation.open") {
                        guard creations.owns(attempt, of: creation) else { return }
                        scopes.applying {
                            creation.opened(id)
                            show(id, creation)
                        }
                    }
                    // The row leaves when the workspace's own row can take its place.
                    guard await Self.mirrored(id, on: session) else { return }
                    await mainWork.apply(.visible, owner: "CloudCreation.mirrored") {
                        guard creations.owns(attempt, of: creation) else { return }
                        creations.remove(creation)
                    }
                } catch is CancellationError {
                    return
                } catch CloudMachineCreateFlow.Failure.declined {
                    // The person said no in the confirmation: the creation closes
                    // quietly (its window shows what it showed before).
                    await mainWork.apply(.visible, owner: "CloudCreation.declined") {
                        guard creations.owns(attempt, of: creation) else { return }
                        creations.remove(creation)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await mainWork.apply(.visible, owner: "CloudCreation.failed") {
                        guard creations.owns(attempt, of: creation) else { return }
                        creation.fail(error)
                    }
                }
            }
        }
    }

    /// Waits for the ready stage (a failure in between may recover: the
    /// daemon keeps retrying). False when cancelled.
    private static func ready(_ creation: CloudMachineCreation, on work: MainWorkScheduler) async -> Bool {
        await ObservedCondition(owner: "CloudCreation.ready", .visible, on: work).until { creation.stage == .ready }
        return !Task.isCancelled && creation.stage == .ready
    }

    /// How long a created workspace may take to reach this Mac's mirror before its row stays as it is.
    private static let mirrorLimit: Duration = .seconds(600)

    /// Whether the machine's store lists workspace `id` (its keyed wait): false after ``mirrorLimit`` or when cancelled.
    private static func mirrored(_ id: String, on session: CloudMachineSession) async -> Bool {
        await session.daemon.store.waitForWorkspace(id: id, timeout: mirrorLimit) != nil
    }
}
