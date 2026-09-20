import Foundation
import Observation
import CmuxCloudMachines

/// Adapts the shared package lifecycle to CLI processes, notifications, and local workspaces.
/// Every New Machine entrypoint uses this owner; views consume immutable projections.
@MainActor
@Observable
final class MachineCreateCoordinator {
    // CloudVMActionLauncher is a legacy process API; callbacks stay at this app seam.
    typealias Launch = @MainActor (
        [String],
        @escaping @MainActor (String) -> Void,
        @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> Bool
    typealias CancellableLaunch = @MainActor (
        [String],
        @escaping @MainActor (String) -> Void,
        @escaping @MainActor (CloudVMActionLauncher.Completion) -> Void
    ) -> CloudVMActionLauncher.CancellationHandle?
    typealias Outcome = CloudMachineCreateTransition.Outcome

    struct Finished: Equatable {
        let operation: MachineCreateOperation
        let outcome: Outcome
    }

    static let shared = MachineCreateCoordinator(
        notifier: MachineCreateNotifier().post,
        cancelCreatedMachine: { CloudVMActionLauncher.shared.destroyMachineBestEffort($0) },
        cancelOperation: { operation in
            guard let workspaceID = operation.request.presentationWorkspaceID else { return }
            NewMachineSheetPresenter.closeReservedWorkspace(workspaceID)
        }
    )
    static let didChangeNotification = Notification.Name("cmux.machineCreate.didChange")
    nonisolated static let finishedUserInfoKey = "finished"

    private let lifecycle: CloudMachineCreateCoordinator
    private(set) var lastFinished: Finished?
    @ObservationIgnored private var requests: [UUID: MachineCreateRequest] = [:]
    @ObservationIgnored private var launches: [UUID: CancellableLaunch] = [:]
    @ObservationIgnored private var handles: [UUID: CloudVMActionLauncher.CancellationHandle] = [:]
    @ObservationIgnored private var workspaceWaiters: [UUID: CheckedContinuation<UUID?, Never>] = [:]
    @ObservationIgnored private let notifier: @MainActor (MachineCreateNotice) -> Void
    @ObservationIgnored private let cancelCreatedMachine: @MainActor (String) -> Void
    @ObservationIgnored private let cancelOperation: @MainActor (MachineCreateOperation) -> Void
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var accessDidEndObserver: NSObjectProtocol?

    init(
        notifier: @escaping @MainActor (MachineCreateNotice) -> Void,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default,
        cancelCreatedMachine: @escaping @MainActor (String) -> Void = { _ in },
        cancelOperation: @escaping @MainActor (MachineCreateOperation) -> Void = { _ in }
    ) {
        self.lifecycle = CloudMachineCreateCoordinator(output: Self.outputParser, now: now)
        self.notifier = notifier
        self.cancelCreatedMachine = cancelCreatedMachine
        self.cancelOperation = cancelOperation
        self.notificationCenter = notificationCenter
        accessDidEndObserver = notificationCenter.addObserver(
            forName: .cmuxCloudVMAccessDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelAllForAuthTransition() }
        }
    }

    deinit {
        if let accessDidEndObserver { notificationCenter.removeObserver(accessDidEndObserver) }
    }

    /// Pending rows projected from the one domain owner; consumers cannot mutate them.
    var operations: [MachineCreateOperation] { lifecycle.projection.operations.compactMap(presentation) }
    /// Session-long aliases keep selection stable after the transient operation retires.
    var adoptedOperationIDs: [String: UUID] { lifecycle.projection.adoptedOperationIDs }
    var hasRunningOperations: Bool { operations.contains(where: \.isRunning) }

    func operation(id: UUID) -> MachineCreateOperation? { operations.first { $0.id == id } }

    /// Registers the pending projection before invoking a legacy noncancellable launcher.
    @discardableResult
    func start(_ request: MachineCreateRequest, launch: @escaping Launch) -> Bool {
        start(request, cancellableLaunch: { arguments, progress, completion in
            guard launch(arguments, progress, completion) else { return nil }
            return CloudVMActionLauncher.CancellationHandle { }
        })
    }

    /// Registers the pending projection before any process, auth, or API work starts.
    @discardableResult
    func start(_ request: MachineCreateRequest, cancellableLaunch: @escaping CancellableLaunch) -> Bool {
        run(reserve(request, launch: cancellableLaunch), launch: cancellableLaunch)
    }

    private func reserve(_ request: MachineCreateRequest, launch: @escaping CancellableLaunch) -> CloudMachineCreateAttempt {
        let attempt = lifecycle.reserve(request.lifecycleRequest)
        requests[attempt.operationID] = request
        launches[attempt.operationID] = launch
        postDidChange()
        return attempt
    }

    /// Waits for this create's exact receipt; cancellation cannot affect another create.
    func startAndAwaitWorkspaceID(_ request: MachineCreateRequest, cancellableLaunch: @escaping CancellableLaunch) async -> UUID? {
        guard !Task.isCancelled else { return nil }
        let attempt = reserve(request, launch: cancellableLaunch)
        let id = attempt.operationID
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                workspaceWaiters[id] = continuation
                guard !Task.isCancelled else {
                    cancel(id)
                    apply(lifecycle.refuse(attempt))
                    resumeWaiter(id, workspaceID: nil)
                    return
                }
                if !run(attempt, launch: cancellableLaunch) { resumeWaiter(id, workspaceID: nil) }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(id)
                self?.resumeWaiter(id, workspaceID: nil)
            }
        })
    }

    /// Reuses the original invocation and idempotency scope with a fresh callback fence.
    @discardableResult
    func retry(_ id: UUID) -> Bool {
        guard let launch = launches[id], let attempt = lifecycle.retry(id) else { return false }
        handles[id] = nil
        postDidChange()
        return run(attempt, launch: launch, isRetry: true)
    }

    /// Dismisses an inline failure and closes its reservation exactly once.
    func dismiss(_ id: UUID) { apply(lifecycle.dismiss(id)) }
    /// Cancels the process after committing a tombstone for late machine receipts.
    func cancel(_ id: UUID) { apply(lifecycle.cancel(id)) }

    /// Releases workspace-owned operations without calling back into workspace closure.
    func cancelOperations(forPresentationWorkspace workspaceID: UUID) {
        cancelOperations(forPresentationWorkspaces: [workspaceID])
    }

    /// Batches a closing window's operation teardown into one domain transition.
    func cancelOperations(forPresentationWorkspaces workspaceIDs: Set<UUID>) {
        apply(lifecycle.cancelPresentations(workspaceIDs))
    }

    /// Clears old-account UI state while allowing cancelled processes to report receipts.
    func cancelAllForAuthTransition(cleanupCreatedMachines: Bool = true) {
        lastFinished = nil
        apply(lifecycle.endAccount(cleanupCreatedMachines: cleanupCreatedMachines))
    }

    /// Retires acknowledged pending rows; retained aliases survive every later refresh.
    func reconcileAuthoritativeState(machineIDs: Set<String>, catalogMachineIDs: Set<String>) {
        if lifecycle.reconcile(machineIDs: machineIDs.union(catalogMachineIDs)) {
            discardRetiredAdapters()
            postDidChange()
        }
    }

    /// Captures the immutable attempt on both callbacks, including synchronous launchers.
    private func run(_ attempt: CloudMachineCreateAttempt, launch: CancellableLaunch, isRetry: Bool = false) -> Bool {
        guard let request = requests[attempt.operationID] else {
            apply(lifecycle.refuse(attempt))
            return false
        }
        let machineID = operation(id: attempt.operationID)?.createdMachineID
        var arguments = request.arguments
        if isRetry, !request.isBaseSetup, let machineID {
            arguments = ["vm", "open", machineID] + (request.presentationWorkspaceID.map { ["--workspace", $0.uuidString] } ?? []) + ["--focus", "false"]
        }
        let handle = launch(arguments, { [weak self] chunk in
            guard let self else { return }
            self.apply(self.lifecycle.receive(chunk, from: attempt))
        }, { [weak self] result in
            guard let self else { return }
            let completion = CloudMachineCreateCompletion(
                succeeded: result.succeeded, wasCancelled: result.wasCancelled, output: result.output,
                failureOutput: Self.displayableFailureOutput(result.output),
                machineID: result.machineId, workspaceID: result.workspaceId
            )
            self.apply(self.lifecycle.finish(completion, from: attempt))
        })
        guard let handle else {
            let failure = isRetry ? String(localized: "machines.new.error.launch", defaultValue: "cmux could not start the create command. Sign in and try again.") : nil
            apply(lifecycle.refuse(attempt, retryFailure: failure))
            return false
        }
        if lifecycle.isActive(attempt) {
            handles[attempt.operationID] = handle
        } else {
            // A reentrant cancellation may precede the launcher's returned handle.
            handle.cancel()
        }
        return true
    }

    /// Applies effects after state commits, so teardown callbacks can safely reenter.
    private func apply(_ transition: CloudMachineCreateTransition) {
        guard transition.changed || !transition.cleanupMachineIDs.isEmpty else { return }
        let closed = transition.closedOperations.compactMap(presentation)
        let finished = transition.finished.flatMap { result -> Finished? in
            guard let operation = presentation(result.operation) else { return nil }
            return Finished(operation: operation, outcome: result.outcome)
        }
        let cancelledHandles = transition.cancelOperationIDs.compactMap { handles.removeValue(forKey: $0) }
        if let finished {
            lastFinished = finished
            let id = finished.operation.id
            handles[id] = nil
            if case .created(_, let workspaceID) = finished.outcome {
                resumeWaiter(id, workspaceID: workspaceID)
                if let workspaceID { selectCreatedWorkspace(workspaceID, for: finished.operation.request) }
            } else {
                resumeWaiter(id, workspaceID: nil)
            }
        }
        discardRetiredAdapters()
        for handle in cancelledHandles { handle.cancel() }
        for machineID in transition.cleanupMachineIDs { cancelCreatedMachine(machineID) }
        for operation in closed { cancelOperation(operation) }
        if let finished {
            let notice = MachineCreateNotice(finished: finished)
            // The reserved workspace and Cloud row already show successful completion.
            // Keep notifications for failures and for creates without that presentation.
            if notice.isFailure || finished.operation.request.reservedWorkspaceID == nil { notifier(notice) }
        }
        if transition.changed { postDidChange(finished: finished) }
    }

    /// Releases only app resources; lifecycle state and callback fences live in the package.
    private func discardRetiredAdapters() {
        let liveIDs = Set(lifecycle.projection.operations.map(\.id))
        for id in Array(requests.keys) where !liveIDs.contains(id) {
            requests[id] = nil
            launches[id] = nil
            handles[id] = nil
            resumeWaiter(id, workspaceID: nil)
        }
    }

    private func presentation(_ operation: CloudMachineCreateOperation) -> MachineCreateOperation? {
        guard let request = requests[operation.id] else { return nil }
        return MachineCreateOperation(
            id: operation.id, request: request, startedAt: operation.startedAt,
            createdMachineID: operation.createdMachineID, phase: operation.phase
        )
    }

    private func resumeWaiter(_ id: UUID, workspaceID: UUID?) {
        workspaceWaiters.removeValue(forKey: id)?.resume(returning: workspaceID)
    }

    private func postDidChange(finished: Finished? = nil) {
        var userInfo: [AnyHashable: Any] = [:]
        if let finished { userInfo[Self.finishedUserInfoKey] = finished }
        notificationCenter.post(name: Self.didChangeNotification, object: self, userInfo: userInfo)
    }

    nonisolated private static var outputParser: CloudMachineCreateOutput {
        CloudMachineCreateOutput(legacyCreatedFormat: String(localized: "cli.vm.create.createdCloudVM", defaultValue: "Created Cloud VM %@"))
    }

    /// Interprets a completed CLI transcript through the shared protocol parser.
    nonisolated static func createdMachineID(fromOutput output: String) -> String? { outputParser.machineID(in: output) }

    /// Redacts at the app boundary before any failure reaches domain state or UI.
    nonisolated static func displayableFailureOutput(_ output: String) -> String {
        let generic = String(localized: "machines.new.error.generic", defaultValue: "The machine could not be created.")
        let stripped = outputParser.failureText(in: output)
        guard !stripped.isEmpty else { return generic }
        let safe = CloudVMActionLauncher.sanitizedCloudVMStartOutput(String(stripped.prefix(4000)))
        guard safe == CloudVMActionLauncher.hiddenOutputPlaceholder else { return safe.isEmpty ? generic : safe }
        guard let reason = CloudVMActionLauncher.firstSafeLine(of: stripped) else { return safe }
        return "\(reason)\n\(safe)"
    }
}
