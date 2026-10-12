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
    /// Time from the attempt's start to `ready`.
    private(set) var readyAfter: Duration?
    /// The flow's work for this creation; cancelled on dismiss and retry.
    @ObservationIgnored var task: Task<Void, Never>?

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
        // task-owner: the creation's one run; cancelled by retry, dismiss or machine removal
        creation.task = Task { @MainActor in
            do {
                let session: CloudMachineSession
                if let existing = creation.session {
                    session = existing
                } else {
                    session = try await create(creation)
                    try Task.checkCancellation()
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
