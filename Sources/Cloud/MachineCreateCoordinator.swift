import Foundation
import Observation

/// Owns every in-flight machine create. A create is not tied to the sheet
/// that started it: the sheet hands over a ``MachineCreateRequest`` and
/// closes, and this object keeps the operation alive, tracks its outcome,
/// and tells the person how it ended. The Machines panel observes
/// ``operations`` to render pending rows; ``didChangeNotification`` fires on
/// every mutation so panels that are not on screen still refresh when a
/// machine lands.
///
/// The coordinator never talks to the backend itself: each `start` receives
/// the launcher that runs the CLI (`cmux vm new …` / `cmux vm base open …`)
/// so the sheet, the Machines panel ＋, Set Up Base, and tests share one path.
@MainActor
@Observable
final class MachineCreateCoordinator {
    /// Starts the CLI with the arguments; returns false when it could not
    /// launch (a sign-out raced the click). The completion carries the exit
    /// status and combined output, which is the error text on failure.
    typealias Launch = @MainActor (
        [String],
        @escaping @MainActor (String) -> Void,
        @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> Bool

    /// The cancellable form used by the app. A nil handle means the child
    /// could not be launched; a successful launch always returns a handle (the
    /// compatibility wrapper below supplies a no-op handle for older callers).
    typealias CancellableLaunch = @MainActor (
        [String],
        @escaping @MainActor (String) -> Void,
        @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> CloudVMActionLauncher.CancellationHandle?

    /// How a create ended.
    enum Outcome: Equatable {
        /// The machine exists and, when the CLI opened it, `workspaceID` is
        /// the local workspace it opened into.
        case created(machineID: String?, workspaceID: UUID?)
        /// `vm new` minted the machine but then failed to open it (terminal
        /// attach, desktop split). The machine is real: the row is dropped in
        /// favor of the fleet row and the person is pointed at the list.
        case createdButOpenFailed(machineID: String, output: String)
        /// Nothing was created; the row stays and offers Retry.
        case failed(output: String)
    }

    struct Finished: Equatable {
        let operation: MachineCreateOperation
        let outcome: Outcome
    }

    static let shared = MachineCreateCoordinator(
        notifier: MachineCreateNotifier().post,
        cancelCreatedMachine: { machineID in
            CloudVMActionLauncher.shared.destroyMachineBestEffort(machineID)
        },
        cancelOperation: { operation in
            guard let workspaceID = operation.request.presentationWorkspaceID,
                  let appDelegate = AppDelegate.shared,
                  let tabManager = appDelegate.tabManagerFor(tabId: workspaceID),
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else { return }
            tabManager.closeWorkspace(workspace, recordHistory: false)
        }
    )

    /// Posted on the default center with `object` = the coordinator after any
    /// change to ``operations``. `userInfo[finishedUserInfoKey]` carries the
    /// ``Finished`` value when the change is a completion.
    static let didChangeNotification = Notification.Name("cmux.machineCreate.didChange")
    nonisolated static let finishedUserInfoKey = "finished"

    var operations: [MachineCreateOperation] = []
    /// The most recent completion, for observers that arrive late (tests,
    /// panels mounted after the fact).
    var lastFinished: Finished?

    /// Bookkeeping, not row state: kept out of observation so a launcher swap
    /// never invalidates views, and so `deinit` (nonisolated) can reach the
    /// observer token without going through an isolated accessor.
    @ObservationIgnored var cancellableLaunches: [UUID: CancellableLaunch] = [:]
    @ObservationIgnored var cancellationHandles: [UUID: CloudVMActionLauncher.CancellationHandle] = [:]
    /// Callback generation per logical create. A retry advances this fence so
    /// a late completion from the previous process cannot finish the retry.
    @ObservationIgnored var attemptGeneration: [UUID: UInt64] = [:]
    @ObservationIgnored var progressOutput: [UUID: String] = [:]
    @ObservationIgnored var progressMarkerCarry: [UUID: String] = [:]
    @ObservationIgnored var cancelledCreates: [UUID: CancelledCreate] = [:]
    @ObservationIgnored var cleanupIssuedMachineIDs: Set<String> = []
    @ObservationIgnored let notifier: @MainActor (MachineCreateNotice) -> Void
    @ObservationIgnored let cancelCreatedMachine: @MainActor (String) -> Void
    @ObservationIgnored let cancelOperation: @MainActor (MachineCreateOperation) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let notificationCenter: NotificationCenter
    @ObservationIgnored private var accessDidEndObserver: NSObjectProtocol?
    @ObservationIgnored private var workspaceWaiters: [UUID: CheckedContinuation<UUID?, Never>] = [:]

    struct CancelledCreate {
        let isBaseSetup: Bool
        let generation: UInt64
        /// Only a bounded tail is retained so a cancelled CLI that continues
        /// streaming logs cannot turn late-result reconciliation into an
        /// unbounded buffer or an O(n²) rescan.
        var markerCarry = ""
        var cleanedMachineID: String?
    }

    static let outputParseLimit = 32 * 1024
    /// The marker parser only needs a short tail to bridge a token split across
    /// callbacks. The full callback is parsed before any transcript bound is
    /// applied, so a marker at the start of a large callback is not lost.
    static let markerCarryLimit = 512
    /// A process that never reports termination must not retain cancellation
    /// state forever. This cap keeps enough tombstones for late callbacks while
    /// bounding memory during a broken sign-out/CLI transport.
    static let maximumCancelledCreates = 64

    init(
        notifier: @escaping @MainActor (MachineCreateNotice) -> Void,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default,
        cancelCreatedMachine: @escaping @MainActor (String) -> Void = { _ in },
        cancelOperation: @escaping @MainActor (MachineCreateOperation) -> Void = { _ in }
    ) {
        self.notifier = notifier
        self.cancelCreatedMachine = cancelCreatedMachine
        self.cancelOperation = cancelOperation
        self.now = now
        self.notificationCenter = notificationCenter
        // A sign-out cancels the launcher's child processes; their late
        // completions must not resurrect rows for an account that is gone.
        accessDidEndObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAllForAuthTransition() }
        }
    }

    deinit {
        if let accessDidEndObserver {
            notificationCenter.removeObserver(accessDidEndObserver)
        }
    }

    var hasRunningOperations: Bool { operations.contains(where: \.isRunning) }

    func operation(id: UUID) -> MachineCreateOperation? {
        operations.first { $0.id == id }
    }

    /// Launches the create and records it. Returns false, recording nothing,
    /// when the launcher refused (the caller shows that inline: the person is
    /// still looking at the sheet at that moment). The operation is registered
    /// BEFORE the launcher runs so a completion that fires synchronously still
    /// finds its row; a refused launch takes the registration back down.
    @discardableResult
    func start(_ request: MachineCreateRequest, launch: @escaping Launch) -> Bool {
        start(request, cancellableLaunch: { arguments, progress, completion in
            guard launch(arguments, progress, completion) else { return nil }
            // Existing test and integration launchers predate cancellation.
            // They still get the same row lifecycle; the no-op handle keeps
            // the new cancellation contract source-compatible for them.
            return CloudVMActionLauncher.CancellationHandle { }
        })
    }

    /// Starts a create with a cancellation handle. The operation is registered
    /// before invoking the launcher so synchronous completion remains safe.
    @discardableResult
    func start(_ request: MachineCreateRequest, cancellableLaunch: @escaping CancellableLaunch) -> Bool {
        start(request, cancellableLaunch: cancellableLaunch, operationID: UUID())
    }

    private func start(
        _ request: MachineCreateRequest,
        cancellableLaunch: @escaping CancellableLaunch,
        operationID: UUID
    ) -> Bool {
        let operation = MachineCreateOperation(id: operationID, request: request, startedAt: now())
        operations.append(operation)
        cancellableLaunches[operation.id] = cancellableLaunch
        progressOutput[operation.id] = ""
        attemptGeneration[operation.id] = 1
        progressMarkerCarry[operation.id] = ""
        postDidChange(finished: nil)
        guard let cancellation = cancellableLaunch(
            request.arguments,
            progressHandler(for: operation.id, generation: 1),
            completionHandler(for: operation.id, generation: 1)
        ) else {
            if let index = operations.firstIndex(where: { $0.id == operation.id }) {
                operations.remove(at: index)
            }
            cancellableLaunches.removeValue(forKey: operation.id)
            progressOutput.removeValue(forKey: operation.id)
            attemptGeneration.removeValue(forKey: operation.id)
            progressMarkerCarry.removeValue(forKey: operation.id)
            postDidChange(finished: nil)
            return false
        }
        // A synchronous completion may already have removed the operation.
        if operations.contains(where: { $0.id == operation.id }) {
            cancellationHandles[operation.id] = cancellation
        }
        return true
    }

    /// Starts a create and awaits the local workspace receipt emitted by the launcher.
    /// The existing coordinator remains the single pending-row mutation path.
    func startAndAwaitWorkspaceID(
        _ request: MachineCreateRequest,
        cancellableLaunch: @escaping CancellableLaunch
    ) async -> UUID? {
        let operationID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                workspaceWaiters[operationID] = continuation
                let started = start(request, cancellableLaunch: { arguments, progress, completion in
                    cancellableLaunch(arguments, progress) { result in
                        completion(result)
                        self.resumeWorkspaceWaiter(operationID, workspaceID: result.succeeded ? result.workspaceId : nil)
                    }
                }, operationID: operationID)
                if !started {
                    resumeWorkspaceWaiter(operationID, workspaceID: nil)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(operationID)
                self?.resumeWorkspaceWaiter(operationID, workspaceID: nil)
            }
        })
    }

    private func resumeWorkspaceWaiter(_ operationID: UUID, workspaceID: UUID?) {
        guard let continuation = workspaceWaiters.removeValue(forKey: operationID) else { return }
        continuation.resume(returning: workspaceID)
    }

    /// Re-runs a failed create with its original arguments and launcher.
    /// Only failures that created nothing are retriable; a "created but
    /// opening failed" outcome never comes back here (a second run would mint
    /// a second machine).
    @discardableResult
    func retry(_ id: UUID) -> Bool {
        guard let index = operations.firstIndex(where: { $0.id == id }),
              operations[index].failureOutput != nil,
              let launch = cancellableLaunches[id] else { return false }
        operations[index].phase = .running
        operations[index].createdMachineID = nil
        let generation = (attemptGeneration[id] ?? 0) &+ 1
        attemptGeneration[id] = generation
        progressOutput[id] = ""
        progressMarkerCarry[id] = ""
        cancellationHandles.removeValue(forKey: id)
        postDidChange(finished: nil)
        guard let cancellation = launch(
            operations[index].request.arguments,
            progressHandler(for: id, generation: generation),
            completionHandler(for: id, generation: generation)
        ) else {
            if let failedIndex = operations.firstIndex(where: { $0.id == id }) {
                operations[failedIndex].phase = .failed(output: String(
                    localized: "machines.new.error.launch",
                    defaultValue: "cmux could not start the create command. Sign in and try again."
                ))
                // Fence callbacks from the refused attempt as well. A launcher
                // may have synchronously delivered a stale termination callback.
                attemptGeneration[id] = (attemptGeneration[id] ?? generation) &+ 1
                postDidChange(finished: nil)
            }
            return false
        }
        if operations.contains(where: { $0.id == id }) {
            cancellationHandles[id] = cancellation
        }
        return true
    }

    /// Drops a failed row. Running creates use ``cancel(_:)`` so the child is
    /// stopped and any machine it announced is cleaned up.
    func dismiss(_ id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }), operations[index].failureOutput != nil else { return }
        let operation = operations.remove(at: index)
        cancellableLaunches.removeValue(forKey: id)
        cancellationHandles.removeValue(forKey: id)
        progressOutput.removeValue(forKey: id)
        attemptGeneration.removeValue(forKey: id)
        progressMarkerCarry.removeValue(forKey: id)
        cancelOperation(operation)
        postDidChange(finished: nil)
    }

    /// Cancels a running create and removes its pending row immediately. The
    /// process completion remains connected long enough to catch a machine id
    /// emitted in its final output; that late machine is destroyed exactly once
    /// through the same delete path as every other VM delete.
    func cancel(_ id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }), operations[index].isRunning else { return }
        let operation = operations.remove(at: index)
        let cancellation = cancellationHandles.removeValue(forKey: id)
        cancellableLaunches.removeValue(forKey: id)
        progressOutput.removeValue(forKey: id)
        let generation = attemptGeneration.removeValue(forKey: id) ?? 0
        var cancelled = CancelledCreate(
            isBaseSetup: operation.request.isBaseSetup,
            generation: generation,
            markerCarry: progressMarkerCarry.removeValue(forKey: id) ?? ""
        )
        if !operation.request.isBaseSetup, let machineID = operation.createdMachineID {
            cancelled.cleanedMachineID = machineID
        }
        retainCancelledCreate(cancelled, for: id)
        // Install the tombstone before terminating: Process may invoke its
        // termination handler synchronously on a test double.
        cancellation?.cancel()
        if !operation.request.isBaseSetup, let machineID = operation.createdMachineID {
            cleanupCancelledMachine(machineID)
        }
        cancelOperation(operation)
        resumeWorkspaceWaiter(id, workspaceID: nil)
        postDidChange(finished: nil)
    }

    /// Forgets every operation. Completions for the dropped ids are ignored.
    func cancelAllForAuthTransition(cleanupCreatedMachines: Bool = true) {
        guard !operations.isEmpty || !cancellableLaunches.isEmpty else { return }
        // Install tombstones before terminating the children. A create can
        // announce its machine after the cancellation handle runs, and that
        // late output still needs to reach the cleanup path during sign-out.
        let runningOperations = operations.filter(\.isRunning)
        let allOperations = operations
        for operation in runningOperations where cleanupCreatedMachines && !operation.request.isBaseSetup {
            var cancelled = CancelledCreate(
                isBaseSetup: false,
                generation: attemptGeneration[operation.id] ?? 0,
                markerCarry: progressMarkerCarry[operation.id] ?? ""
            )
            if let machineID = operation.createdMachineID {
                cancelled.cleanedMachineID = machineID
            }
            retainCancelledCreate(cancelled, for: operation.id)
        }
        let handles = Array(cancellationHandles.values)
        operations.removeAll()
        cancellableLaunches.removeAll()
        cancellationHandles.removeAll()
        attemptGeneration.removeAll()
        progressOutput.removeAll()
        progressMarkerCarry.removeAll()
        // Keep new-machine tombstones until their process callbacks arrive so
        // a machine announced after sign-out still receives best-effort cleanup.
        // Base setup has no newly allocated machine to destroy and can be
        // discarded immediately.
        for (id, cancelled) in cancelledCreates where cancelled.isBaseSetup {
            cancelledCreates[id] = nil
        }
        for operation in runningOperations where cleanupCreatedMachines && !operation.request.isBaseSetup {
            if let machineID = operation.createdMachineID {
                cleanupCancelledMachine(machineID)
            }
        }
        // A reserved loading workspace belongs to the create operation even
        // when no provider id was announced. Tear it down with the operation
        // so sign-out cannot leave an orphan local projection behind.
        for operation in allOperations {
            cancelOperation(operation)
        }
        for handle in handles { handle.cancel() }
        for operationID in Array(workspaceWaiters.keys) {
            resumeWorkspaceWaiter(operationID, workspaceID: nil)
        }
        postDidChange(finished: nil)
    }

    /// Recognizes the CLI's "Created Cloud VM <id>" line in `output`. The
    /// format is the CLI's own localized string, so the match follows the
    /// user's language instead of a hard-coded English prefix.
    nonisolated static func createdMachineID(fromOutput output: String) -> String? {
        // The stable marker is emitted before opening starts and is the
        // authoritative correlation key. Parse it before localized display
        // text, so partial progress can identify the machine in every locale.
        for token in output.split(whereSeparator: \.isWhitespace) {
            let token = String(token)
            guard token.hasPrefix("machine=") else { continue }
            let id = String(token.dropFirst("machine=".count))
            if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                return id
            }
        }
        let format = String(localized: "cli.vm.create.createdCloudVM", defaultValue: "Created Cloud VM %@")
        let parts = format.components(separatedBy: "%@")
        guard parts.count == 2 else { return nil }
        let prefix = parts[0], suffix = parts[1]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { continue }
            let id = String(line.dropFirst(prefix.count).dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { return id }
        }
        return nil
    }

    /// The failure text every surface shows (row tooltip, control bar, Show
    /// Error, Copy Error, notification): the CLI transcript with the app's
    /// standard redaction applied once, at storage time. Progress/token lines
    /// ("Created Cloud VM …", "OK machine=…") are dropped first so the reason
    /// leads. Redacted transcripts fall back to their first safe line plus the
    /// hidden-details placeholder, matching `CloudVMActionLauncher`'s alerts.
    nonisolated static func displayableFailureOutput(_ output: String) -> String {
        let generic = String(localized: "machines.new.error.generic", defaultValue: "The machine could not be created.")
        let stripped = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("OK ") && Self.createdMachineID(fromOutput: trimmed) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return generic }
        let safe = CloudVMActionLauncher.sanitizedCloudVMStartOutput(String(stripped.prefix(4000)))
        guard safe == CloudVMActionLauncher.hiddenOutputPlaceholder else {
            return safe.isEmpty ? generic : safe
        }
        guard let reason = CloudVMActionLauncher.firstSafeLine(of: stripped) else { return safe }
        return "\(reason)\n\(safe)"
    }


}
