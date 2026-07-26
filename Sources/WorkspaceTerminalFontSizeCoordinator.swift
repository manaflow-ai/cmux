import Foundation
import CmuxFoundation
import CmuxTerminal
import CmuxTerminalCore
import OSLog

struct WorkspaceTerminalFontConfigurationSnapshot: Equatable {
    let configuredRuntimePoints: Float32
    let magnificationPercent: Int
}

@MainActor
final class WorkspaceTerminalFontSizeCoordinator {
    typealias Arbiter = WorkspaceTerminalFontSizeArbiter
    typealias DrainCancellation = @MainActor () -> Void
    typealias DrainScheduler =
        @MainActor (
            TimeInterval,
            @escaping @MainActor () -> Void
        ) -> DrainCancellation
    typealias ChangeApplier =
        @MainActor (
            WorkspaceTerminalFontSizeChange,
            TerminalPanel,
            Float32,
            Int
        ) -> TerminalFontSizeMutationOutcome
    typealias ConfigurationSnapshotProvider =
        @MainActor () -> WorkspaceTerminalFontConfigurationSnapshot

    private static let repeatCoalescingInterval: TimeInterval = 0.05
    private static let mutationRetryBackoffInterval: TimeInterval = 0.05

    private enum MutationRetryDisposition {
        case ready
        case backoff
        case awaitingSignal
    }

    private enum CoordinatedMutationDisposition {
        case succeeded
        case retry
        case skipCandidate
    }

    private static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "WorkspaceTerminalFontSize"
    )

    final class WeakWorkspaceReference {
        weak var value: Workspace?

        init(_ value: Workspace) {
            self.value = value
        }
    }

    /// Stable identity for one window's Dock, including the interval before
    /// its store is created. Requests keep the slot when workspace ownership
    /// forwards their execution to another window's coordinator.
    final class WindowDockSlot {
        weak var value: DockSplitStore?
        weak var coordinator: WorkspaceTerminalFontSizeCoordinator?
        var pendingLineage: TerminalFontSizeLineage?
        var pendingInheritanceContext:
            TerminalFontSizeChangeInheritanceContext?

        init(_ value: DockSplitStore? = nil) {
            self.value = value
        }

        func clearPendingInheritanceContext(token: UUID) {
            guard pendingInheritanceContext?.token == token else { return }
            pendingInheritanceContext = nil
        }
    }

    /// Shared result for the Dock and workspace phases of one coalesced event
    /// batch. The Dock phase always precedes the workspace phases in the sealed
    /// ledger, so workspace fallbacks can derive from the bounded source probe.
    private final class EventBatchLineage {
        let configuration:
            WorkspaceTerminalFontConfigurationSnapshot
        var windowDockSourceLineage: TerminalFontSizeLineage?
        var windowDockSourceLineageSelection =
            TerminalFontSizeLineageSelection()
        var windowDockLineageSelection =
            TerminalFontSizeLineageSelection()
        var didParticipateWindowDock = false
        var remainingRequestTokens: Set<UUID> = []
        let windowDockTransferToken = UUID()
        let workspaceTransferToken = UUID()

        init(
            configuration:
                WorkspaceTerminalFontConfigurationSnapshot
        ) {
            self.configuration = configuration
        }
    }

    private enum RequestResourceKey: Hashable {
        case workspace(UUID)
        case windowDock(ObjectIdentifier)
    }

    private enum RequestTarget {
        case workspace(
            id: UUID,
            reference: WeakWorkspaceReference
        )
        case windowDock(
            slot: WindowDockSlot,
            seedWorkspace: WeakWorkspaceReference?
        )
    }

    private struct PendingRequest {
        let token: UUID
        let sequence: UInt64
        let resourceKey: RequestResourceKey
        let target: RequestTarget
        let batchLineage: EventBatchLineage
        /// Ordered Dock changes through this workspace's most recent event.
        /// This is a constant-size value transform, not a panel snapshot.
        var windowDockPrefixChange: WorkspaceTerminalFontSizeChange?
        var change: WorkspaceTerminalFontSizeChange
    }

    private final class TransferRequestRecord {
        let request: PendingRequest
        let configuredRuntimePoints: Float32
        let magnificationPercent: Int
        weak var previous: TransferRequestRecord?
        var next: TransferRequestRecord?

        init(
            request: PendingRequest,
            configuredRuntimePoints: Float32,
            magnificationPercent: Int
        ) {
            self.request = request
            self.configuredRuntimePoints = configuredRuntimePoints
            self.magnificationPercent = magnificationPercent
        }
    }

    private final class TransferObligation {
        weak var panel: TerminalPanel?
        let panelId: UUID
        weak var resourceState: TransferResourceState?
        var nextRequest: TransferRequestRecord?
        var throughRequest: TransferRequestRecord
        var heapIndex: Int?
        var heapOrder: UInt64 = 0

        init(
            panel: TerminalPanel,
            resourceState: TransferResourceState,
            nextRequest: TransferRequestRecord,
            throughRequest: TransferRequestRecord
        ) {
            self.panel = panel
            panelId = panel.id
            self.resourceState = resourceState
            self.nextRequest = nextRequest
            self.throughRequest = throughRequest
        }
    }

    private final class TransferResourceState {
        private(set) var outstandingRequestCount = 0
        private(set) var firstRequest: TransferRequestRecord?
        private(set) var lastRequest: TransferRequestRecord?
        private var obligationsByPanelId: [UUID: TransferObligation] = [:]

        func appendRequest(_ record: TransferRequestRecord) {
            outstandingRequestCount += 1
            record.previous = lastRequest
            lastRequest?.next = record
            if firstRequest == nil {
                firstRequest = record
            }
            lastRequest = record
        }

        @discardableResult
        func retireRequest(token: UUID) -> Bool {
            precondition(outstandingRequestCount > 0)
            guard let record = firstRequest else {
                preconditionFailure("Missing transfer request record")
            }
            precondition(record.request.token == token)
            firstRequest = record.next
            firstRequest?.previous = nil
            if lastRequest === record {
                lastRequest = nil
            }
            record.next = nil
            outstandingRequestCount -= 1
            return outstandingRequestCount == 0
        }

        func register(
            panel: TerminalPanel
        ) -> (obligation: TransferObligation, isNew: Bool)? {
            guard let firstRequest, let lastRequest else { return nil }
            if let existing = obligationsByPanelId[panel.id] {
                existing.throughRequest = lastRequest
                return (existing, false)
            }
            let obligation = TransferObligation(
                panel: panel,
                resourceState: self,
                nextRequest: firstRequest,
                throughRequest: lastRequest
            )
            obligationsByPanelId[panel.id] = obligation
            return (obligation, true)
        }

        func remove(_ obligation: TransferObligation) {
            guard obligationsByPanelId.removeValue(
                forKey: obligation.panelId
            ) === obligation else {
                return
            }
            obligation.resourceState = nil
            obligation.nextRequest = nil
        }

        var obligations: Dictionary<UUID, TransferObligation>.Values {
            obligationsByPanelId.values
        }
    }

    private struct PendingEventBatch {
        let windowDockSlotIdentity: ObjectIdentifier
        let lineage: EventBatchLineage
        var windowDockRequest: PendingRequest
        var workspaceRequests: [UUID: PendingRequest] = [:]
        var workspaceOrder: [UUID] = []
    }

    private struct PendingRequestQueue {
        private var storage: [PendingRequest] = []
        private var head = 0

        var isEmpty: Bool {
            head >= storage.count
        }

        var count: Int {
            storage.count - head
        }

        var elements: ArraySlice<PendingRequest> {
            storage[head...]
        }

        var first: PendingRequest? {
            guard !isEmpty else { return nil }
            return storage[head]
        }

        mutating func append(_ request: PendingRequest) {
            storage.append(request)
        }

        mutating func popFirst() -> PendingRequest? {
            guard !isEmpty else { return nil }
            let request = storage[head]
            head += 1
            if head == storage.count {
                storage.removeAll(keepingCapacity: false)
                head = 0
            } else if head >= 16, head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
            }
            return request
        }

        mutating func removeAll() {
            storage.removeAll(keepingCapacity: false)
            head = 0
        }

        mutating func removeAll(
            where shouldRemove: (PendingRequest) -> Bool
        ) -> [PendingRequest] {
            var removed: [PendingRequest] = []
            var retained: [PendingRequest] = []
            for request in elements {
                if shouldRemove(request) {
                    removed.append(request)
                } else {
                    retained.append(request)
                }
            }
            storage = retained
            head = 0
            return removed
        }
    }

    private struct ActiveRequest {
        let request: PendingRequest
        let inheritanceContext: TerminalFontSizeChangeInheritanceContext
        var discovery: WorkspaceTerminalFontSizePanelDiscovery
        var pendingCandidate:
            WorkspaceTerminalFontSizePanelDiscovery.Candidate?
        var seenPanelIds: Set<UUID> = []
        var participatingLineage = TerminalFontSizeLineageSelection()
        let configuredRuntimePoints: Float32
        let magnificationPercent: Int

        var token: UUID {
            request.token
        }
    }

    private weak var tabManager: TabManager?
    private let windowDockSlot = WindowDockSlot()

    private var windowDock: DockSplitStore? {
        windowDockSlot.value
    }

    private var pendingEventBatch: PendingEventBatch?
    private var sealedRequests = PendingRequestQueue()
    private var activeRequest: ActiveRequest?
    private var nextRequestSequence: UInt64 = 0
    private var transferResourceStates:
        [RequestResourceKey: TransferResourceState] = [:]
    private var transferObligations: [TransferObligation] = []
    private var nextTransferObligationOrder: UInt64 = 0
    private var windowDockResourceKeys:
        [ObjectIdentifier: RequestResourceKey] = [:]
    private var activeBatchLineages:
        [ObjectIdentifier: EventBatchLineage] = [:]
    private var activeTransferRequestTokens: Set<UUID> = []
    private var isDraining = false
    private var mutationRetryDisposition:
        MutationRetryDisposition = .ready
    private var automaticMutationRetryAvailable = true
    private var isSettlingForFontSizeWorkIdleBarrier = false
    private var mutationFailureCountSinceIdleBarrier = 0
    private let arbiter: WorkspaceTerminalFontSizeArbiter
    private let maximumOutstandingRequestCount: Int
    private let schedule: DrainScheduler
    private let applyChange: ChangeApplier
    private let configurationSnapshot:
        ConfigurationSnapshotProvider
    private var cancelScheduledDrain: DrainCancellation?

    init(
        tabManager: TabManager,
        arbiter: WorkspaceTerminalFontSizeArbiter =
            WorkspaceTerminalFontSizeArbiter(),
        maximumOutstandingRequestCount: Int = 256,
        schedule: @escaping DrainScheduler = { delay, action in
            let boundedDelay = max(0, delay)
            let maximumDelay =
                Double(Int.max) / 1_000_000_000.0
            let nanoseconds = Int(
                (
                    min(boundedDelay, maximumDelay)
                    * 1_000_000_000.0
                ).rounded(.up)
            )
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(
                deadline: .now() + .nanoseconds(nanoseconds)
            )
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    action()
                }
            }
            timer.resume()
            return {
                timer.setEventHandler {}
                timer.cancel()
            }
        },
        configurationSnapshot: @escaping
            ConfigurationSnapshotProvider = {
                GhosttyApp.shared
                    .terminalFontConfigurationSnapshot()
            },
        applyChange: @escaping ChangeApplier = {
            change,
            terminalPanel,
            configuredRuntimePoints,
            magnificationPercent in
            cmuxApplyTerminalFontSizeChange(
                change,
                to: terminalPanel,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
        }
    ) {
        precondition(maximumOutstandingRequestCount >= 2)
        self.tabManager = tabManager
        self.arbiter = arbiter
        self.maximumOutstandingRequestCount =
            maximumOutstandingRequestCount
        self.schedule = schedule
        self.configurationSnapshot = configurationSnapshot
        self.applyChange = applyChange
    }

    func attachWindowDock(_ dock: DockSplitStore) {
        windowDockSlot.value = dock
        let requestCoordinator = windowDockSlot.coordinator ?? self
        requestCoordinator.signalMutationRetry()
        requestCoordinator.windowDockResourceKeys[ObjectIdentifier(dock)] =
            .windowDock(ObjectIdentifier(windowDockSlot))
        dock.terminalFontSizeChangeCoordinator = requestCoordinator
        dock.terminalFontSizeOwningWorkspace = nil
        if let inheritanceContext =
                windowDockSlot.pendingInheritanceContext {
            dock.beginTerminalFontSizeChangeInheritance(
                token: inheritanceContext.token,
                change: inheritanceContext.change,
                configuredRuntimePoints:
                    inheritanceContext.configuredRuntimePoints,
                magnificationPercent:
                    inheritanceContext.magnificationPercent,
                fallbackLineage: inheritanceContext.fallbackLineage,
                fallbackLineageAlreadyIncludesChange: true
            )
        } else {
            dock.rememberTerminalFontSizeLineageForNewTerminals(
                fallback: windowDockSlot.pendingLineage
            )
        }
        windowDockSlot.pendingLineage = nil
        windowDockSlot.pendingInheritanceContext = nil
    }

    @discardableResult
    func enqueue(
        _ change: WorkspaceTerminalFontSizeChange,
        workspaceId: UUID,
        deferFlush: Bool
    ) -> Bool {
        guard !change.isNoOp,
              let workspace = tabManager?.workspacesById[workspaceId] else {
            return false
        }
        arbiter.promoteDeferredCoordinatorJoins()
        let workspaceReference = WeakWorkspaceReference(workspace)
        if let accepted =
                arbiter
                    .deferCoordinatorJoinAfterFontSizeWorkIdleIfNeeded(
                        change,
                        workspace: workspace,
                        workspaceReference: workspaceReference,
                        windowDockSlot: windowDockSlot,
                        preferredCoordinator: self,
                        deferFlush: deferFlush
                    ) {
            return accepted
        }
        workspace.terminalFontSizeChangeCoordinator?
            .signalMutationRetry()
        windowDockSlot.coordinator?.signalMutationRetry()
        if arbiter.hasDeferredCoordinatorJoin(
            targeting: workspace,
            or: windowDockSlot
        ) {
            return deferCoordinatorJoin(
                change,
                workspace: workspace,
                workspaceReference: workspaceReference,
                windowDockSlot: windowDockSlot,
                deferFlush: deferFlush
            )
        }
        let workspaceCoordinator =
            coordinatorOwningWork(for: workspace)
        let windowDockCoordinator =
            coordinatorOwningWork(for: windowDockSlot)
        if let workspaceCoordinator,
           let windowDockCoordinator,
           workspaceCoordinator !== windowDockCoordinator {
            return deferCoordinatorJoin(
                change,
                workspace: workspace,
                workspaceReference: workspaceReference,
                windowDockSlot: windowDockSlot,
                deferFlush: deferFlush
            )
        }
        let eventCoordinator =
            workspaceCoordinator
            ?? windowDockCoordinator
            ?? self
        eventCoordinator.signalMutationRetry(
            scheduleIfOutstanding: false
        )
        guard eventCoordinator.appendEvent(
            change,
            workspaceId: workspaceId,
            workspaceReference: workspaceReference,
            windowDockSlot: windowDockSlot
        ) else {
            eventCoordinator.scheduleOutstandingContinuation()
            return false
        }
        eventCoordinator.claimWorkspace(workspace)
        eventCoordinator.claimWindowDockSlot(windowDockSlot)
        eventCoordinator.flushOrSchedule(deferFlush: deferFlush)
        return true
    }

    func cancelAll() {
        invalidateScheduledDrain()
        if let activeRequest {
            cancelInheritance(for: activeRequest)
        }
        clearAllTransferReconciliationMarks()
        releaseAllClaims()
        activeRequest = nil
        pendingEventBatch = nil
        sealedRequests.removeAll()
        resetMutationRetryState()
        arbiter.removeDeferredCoordinatorJoins(
            preferredCoordinator: self
        )
        windowDockSlot.pendingLineage = nil
        windowDockSlot.pendingInheritanceContext = nil
        arbiter.promoteDeferredCoordinatorJoins()
        releaseRetentionIfIdle()
    }

    /// Cancels work whose targets still belong to this closing window while
    /// allowing requests that followed moved workspaces or foreign Dock slots
    /// to finish on their surviving owners.
    func cancelWindowOwnedWork() {
        arbiter.cancelWindowOwnedWork(
            requestedBy: self,
            closingManager: tabManager,
            closingWindowDockSlot: windowDockSlot
        )
    }

    func cancelWork(
        targeting closingManager: TabManager?,
        windowDockSlot closingWindowDockSlot: WindowDockSlot
    ) {
        invalidateScheduledDrain()
        sealPendingEventBatch()

        var removedRequests: [PendingRequest] = []
        if let activeRequest,
           requestBelongsToClosingWindow(
                activeRequest.request,
                closingManager: closingManager,
                windowDockSlot: closingWindowDockSlot
           ) {
            cancelInheritance(for: activeRequest)
            removedRequests.append(activeRequest.request)
            self.activeRequest = nil
        }
        removedRequests.append(
            contentsOf: sealedRequests.removeAll {
                requestBelongsToClosingWindow(
                    $0,
                    closingManager: closingManager,
                    windowDockSlot: closingWindowDockSlot
                )
            }
        )
        for request in removedRequests {
            retire(request)
            releaseClaimIfIdle(for: request)
        }

        if !hasOutstandingWork(for: closingWindowDockSlot) {
            closingWindowDockSlot.pendingLineage = nil
            closingWindowDockSlot.pendingInheritanceContext = nil
            releaseWindowDockClaimIfIdle(closingWindowDockSlot)
        }
        if activeRequest != nil || hasPendingRequests {
            retainWhileOutstanding()
            signalMutationRetry(scheduleIfOutstanding: false)
            scheduleOutstandingContinuation()
        } else {
            releaseRetentionIfIdle()
        }
    }

#if DEBUG
    private(set) var debugLastSynchronousTransferRequestVisitCount = 0
    private(set) var debugLastPanelDiscoveryConstructionVisitCount = 0

    func debugFlushOneDrain() {
        invalidateScheduledDrain()
        signalMutationRetry(scheduleIfOutstanding: false)
        drain()
    }

    func debugDrainAll() {
        invalidateScheduledDrain()
        signalMutationRetry(scheduleIfOutstanding: false)
        while activeRequest != nil || hasPendingRequests {
            if mutationRetryDisposition == .backoff {
                mutationRetryDisposition = .ready
            } else if mutationRetryDisposition == .awaitingSignal {
                break
            }
            drain(scheduleContinuation: false)
        }
    }

    var debugPendingRequestCount: Int {
        let pendingWorkspaceCount =
            pendingEventBatch?.workspaceRequests.count ?? 0
        let sealedWorkspaceCount = sealedRequests.elements.count {
            if case .workspace = $0.target { return true }
            return false
        }
        let activeWorkspaceCount: Int
        if let activeRequest,
           case .workspace = activeRequest.request.target {
            activeWorkspaceCount = 1
        } else {
            activeWorkspaceCount = 0
        }
        return pendingWorkspaceCount
            + sealedWorkspaceCount
            + activeWorkspaceCount
    }

    var debugOutstandingRequestCount: Int {
        outstandingRequestCount
    }
#endif

    private var hasPendingRequests: Bool {
        pendingEventBatch != nil || !sealedRequests.isEmpty
    }

    private var pendingEventRequestCount: Int {
        guard let pendingEventBatch else { return 0 }
        return 1 + pendingEventBatch.workspaceRequests.count
    }

    private var outstandingRequestCount: Int {
        (activeRequest == nil ? 0 : 1)
            + sealedRequests.count
            + pendingEventRequestCount
    }

    private func retainWhileOutstanding() {
        arbiter.retain(self)
    }

    func releaseRetentionIfIdle() {
        guard activeRequest == nil,
              !hasPendingRequests,
              !arbiter.hasDeferredCoordinatorJoin(
                preferredCoordinator: self
              ) else {
            return
        }
        isSettlingForFontSizeWorkIdleBarrier = false
        mutationFailureCountSinceIdleBarrier = 0
        arbiter.release(self)
    }

    func attachedWorkspace(
        id: UUID,
        reference: WeakWorkspaceReference
    ) -> Workspace? {
        guard let workspace = reference.value,
              workspace.id == id,
              let owningManager = workspace.owningTabManager,
              owningManager.workspacesById[id] === workspace else {
            return nil
        }
        return workspace
    }

    func coordinatorOwningWork(
        for workspace: Workspace
    ) -> WorkspaceTerminalFontSizeCoordinator? {
        guard let coordinator =
                workspace.terminalFontSizeChangeCoordinator else {
            return nil
        }
        guard coordinator.hasOutstandingWork(for: workspace) else {
            if workspace.terminalFontSizeChangeCoordinator === coordinator {
                workspace.terminalFontSizeChangeCoordinator = nil
            }
            return nil
        }
        return coordinator
    }

    func coordinatorOwningWork(
        for slot: WindowDockSlot
    ) -> WorkspaceTerminalFontSizeCoordinator? {
        guard let coordinator = slot.coordinator else {
            return nil
        }
        guard coordinator.hasOutstandingWork(for: slot) else {
            if slot.coordinator === coordinator {
                slot.coordinator = nil
            }
            if slot.value?.terminalFontSizeChangeCoordinator
                    === coordinator {
                slot.value?.terminalFontSizeChangeCoordinator = nil
            }
            return nil
        }
        return coordinator
    }

    private func deferCoordinatorJoin(
        _ change: WorkspaceTerminalFontSizeChange,
        workspace: Workspace,
        workspaceReference: WeakWorkspaceReference,
        windowDockSlot: WindowDockSlot,
        deferFlush: Bool
    ) -> Bool {
        arbiter.deferCoordinatorJoin(
            change,
            workspace: workspace,
            workspaceReference: workspaceReference,
            windowDockSlot: windowDockSlot,
            preferredCoordinator: self,
            deferFlush: deferFlush
        )
    }

    func claimWorkspace(_ workspace: Workspace) {
        workspace.terminalFontSizeChangeCoordinator = self
        workspace._dockSplit?.terminalFontSizeChangeCoordinator = self
        workspace._dockSplit?.terminalFontSizeOwningWorkspace = workspace
    }

    func claimWindowDockSlot(_ slot: WindowDockSlot) {
        slot.coordinator = self
        slot.value?.terminalFontSizeChangeCoordinator = self
        slot.value?.terminalFontSizeOwningWorkspace = nil
        if let dock = slot.value {
            windowDockResourceKeys[ObjectIdentifier(dock)] =
                .windowDock(ObjectIdentifier(slot))
        }
    }

    private func hasOutstandingWork(for workspace: Workspace) -> Bool {
        if let activeRequest,
           request(activeRequest.request, targets: workspace) {
            return true
        }
        if let request =
                pendingEventBatch?.workspaceRequests[workspace.id],
           self.request(request, targets: workspace) {
            return true
        }
        return sealedRequests.elements.contains {
            request($0, targets: workspace)
        }
    }

    private func request(
        _ request: PendingRequest,
        targets workspace: Workspace
    ) -> Bool {
        guard case .workspace(let workspaceId, let reference) =
                request.target else {
            return false
        }
        return workspaceId == workspace.id
            && reference.value === workspace
    }

    private func hasOutstandingWork(for dock: DockSplitStore) -> Bool {
        if let activeRequest,
           request(activeRequest.request, targets: dock) {
            return true
        }
        if let request = pendingEventBatch?.windowDockRequest,
           self.request(request, targets: dock) {
            return true
        }
        return sealedRequests.elements.contains {
            request($0, targets: dock)
        }
    }

    private func hasOutstandingWork(for slot: WindowDockSlot) -> Bool {
        if let activeRequest,
           request(activeRequest.request, targets: slot) {
            return true
        }
        if let request = pendingEventBatch?.windowDockRequest,
           self.request(request, targets: slot) {
            return true
        }
        return sealedRequests.elements.contains {
            request($0, targets: slot)
        }
    }

    private func request(
        _ request: PendingRequest,
        targets dock: DockSplitStore
    ) -> Bool {
        guard case .windowDock(let slot, _) = request.target else {
            return false
        }
        return slot.value === dock
    }

    private func request(
        _ request: PendingRequest,
        targets slot: WindowDockSlot
    ) -> Bool {
        guard case .windowDock(let requestSlot, _) = request.target else {
            return false
        }
        return requestSlot === slot
    }

    private func requestBelongsToClosingWindow(
        _ request: PendingRequest,
        closingManager: TabManager?,
        windowDockSlot closingWindowDockSlot: WindowDockSlot
    ) -> Bool {
        switch request.target {
        case .workspace(_, let reference):
            guard let workspace = reference.value else { return true }
            guard let closingManager else { return false }
            return workspace.owningTabManager === closingManager
        case .windowDock(let requestSlot, _):
            return requestSlot === closingWindowDockSlot
        }
    }

    private func releaseClaimIfIdle(for request: PendingRequest) {
        switch request.target {
        case .workspace(_, let reference):
            releaseWorkspaceClaimIfIdle(reference.value)
        case .windowDock(let slot, _):
            releaseWindowDockClaimIfIdle(slot)
        }
    }

    private func releaseWorkspaceClaimIfIdle(_ workspace: Workspace?) {
        guard let workspace,
              workspace.terminalFontSizeChangeCoordinator === self,
              !hasOutstandingWork(for: workspace) else {
            return
        }
        workspace.terminalFontSizeChangeCoordinator = nil
        arbiter.promoteDeferredCoordinatorJoins()
    }

    private func releaseWindowDockClaimIfIdle(_ slot: WindowDockSlot?) {
        guard let slot,
              slot.coordinator === self,
              !hasOutstandingWork(for: slot) else {
            return
        }
        slot.coordinator = nil
        if slot.value?.terminalFontSizeChangeCoordinator === self {
            slot.value?.terminalFontSizeChangeCoordinator = nil
        }
        arbiter.promoteDeferredCoordinatorJoins()
    }

    private func releaseAllClaims() {
        var workspacesByIdentity: [ObjectIdentifier: Workspace] = [:]
        var dockSlotsByIdentity: [ObjectIdentifier: WindowDockSlot] = [:]
        func collect(_ request: PendingRequest) {
            switch request.target {
            case .workspace(_, let reference):
                guard let workspace = reference.value else { return }
                workspacesByIdentity[ObjectIdentifier(workspace)] =
                    workspace
            case .windowDock(let slot, _):
                dockSlotsByIdentity[ObjectIdentifier(slot)] = slot
            }
        }
        if let activeRequest {
            collect(activeRequest.request)
        }
        pendingEventBatch?.workspaceRequests.values.forEach(collect)
        if let request = pendingEventBatch?.windowDockRequest {
            collect(request)
        }
        sealedRequests.elements.forEach(collect)
        for workspace in workspacesByIdentity.values
        where workspace.terminalFontSizeChangeCoordinator === self {
            workspace.terminalFontSizeChangeCoordinator = nil
        }
        for slot in dockSlotsByIdentity.values
        where slot.coordinator === self {
            slot.coordinator = nil
            if slot.value?.terminalFontSizeChangeCoordinator === self {
                slot.value?.terminalFontSizeChangeCoordinator = nil
            }
        }
    }

    func flushOrSchedule(deferFlush: Bool) {
        if deferFlush {
            scheduleDrain(after: Self.repeatCoalescingInterval)
        } else {
            invalidateScheduledDrain()
            drain()
        }
    }

    func appendEvent(
        _ change: WorkspaceTerminalFontSizeChange,
        workspaceId: UUID,
        workspaceReference: WeakWorkspaceReference,
        windowDockSlot: WindowDockSlot
    ) -> Bool {
        let additionalRequestCount: Int
        if let pendingEventBatch,
           pendingEventBatch.windowDockSlotIdentity
                == ObjectIdentifier(windowDockSlot) {
            additionalRequestCount =
                pendingEventBatch.workspaceRequests[workspaceId] == nil
                ? 1
                : 0
        } else {
            additionalRequestCount = 2
        }
        guard outstandingRequestCount + additionalRequestCount
                <= maximumOutstandingRequestCount else {
            return false
        }

        retainWhileOutstanding()
        let windowDockSlotIdentity = ObjectIdentifier(windowDockSlot)
        if let pendingEventBatch,
           pendingEventBatch.windowDockSlotIdentity
                != windowDockSlotIdentity {
            sealPendingEventBatch()
        }

        if var batch = pendingEventBatch {
            append(change, to: &batch.windowDockRequest)
            pendingEventBatch = batch
        } else {
            let lineage = EventBatchLineage(
                configuration: configurationSnapshot()
            )
            nextRequestSequence += 1
            let windowDockRequest = PendingRequest(
                token: UUID(),
                sequence: nextRequestSequence,
                resourceKey:
                    .windowDock(ObjectIdentifier(windowDockSlot)),
                target: .windowDock(
                    slot: windowDockSlot,
                    seedWorkspace: workspaceReference
                ),
                batchLineage: lineage,
                windowDockPrefixChange: nil,
                change: change
            )
            pendingEventBatch = PendingEventBatch(
                windowDockSlotIdentity: windowDockSlotIdentity,
                lineage: lineage,
                windowDockRequest: windowDockRequest
            )
        }

        guard var batch = pendingEventBatch else { return false }
        if var existing = batch.workspaceRequests[workspaceId] {
            append(change, to: &existing)
            existing.windowDockPrefixChange =
                batch.windowDockRequest.change
            batch.workspaceRequests[workspaceId] = existing
        } else {
            batch.workspaceOrder.append(workspaceId)
            nextRequestSequence += 1
            batch.workspaceRequests[workspaceId] = PendingRequest(
                token: UUID(),
                sequence: nextRequestSequence,
                resourceKey: .workspace(workspaceId),
                target: .workspace(
                    id: workspaceId,
                    reference: workspaceReference
                ),
                batchLineage: batch.lineage,
                windowDockPrefixChange:
                    batch.windowDockRequest.change,
                change: change
            )
        }
        pendingEventBatch = batch
        return true
    }

    private func append(
        _ change: WorkspaceTerminalFontSizeChange,
        to request: inout PendingRequest
    ) {
        append(change, to: &request.change)
    }

    private func append(
        _ change: WorkspaceTerminalFontSizeChange,
        to existing: inout WorkspaceTerminalFontSizeChange
    ) {
        switch change {
        case .relative(let transform):
            existing.append(transform)
        case .resetThen(let transform):
            existing.appendReset()
            existing.append(transform)
        }
    }

    private func sealPendingEventBatch() {
        guard let batch = pendingEventBatch else { return }
        pendingEventBatch = nil
        registerOutstanding(batch.windowDockRequest)
        batch.lineage.remainingRequestTokens.insert(
            batch.windowDockRequest.token
        )
        sealedRequests.append(batch.windowDockRequest)
        for workspaceId in batch.workspaceOrder {
            guard let request = batch.workspaceRequests[workspaceId] else {
                continue
            }
            registerOutstanding(request)
            batch.lineage.remainingRequestTokens.insert(request.token)
            sealedRequests.append(request)
        }
    }

    private func registerOutstanding(_ request: PendingRequest) {
        let configuration = request.batchLineage.configuration
        let state =
            transferResourceStates[request.resourceKey]
            ?? TransferResourceState()
        state.appendRequest(
            TransferRequestRecord(
                request: request,
                configuredRuntimePoints:
                    configuration.configuredRuntimePoints,
                magnificationPercent:
                    configuration.magnificationPercent
            )
        )
        transferResourceStates[request.resourceKey] = state
        activeBatchLineages[
            ObjectIdentifier(request.batchLineage)
        ] = request.batchLineage
        if case .windowDock(let slot, _) = request.target,
           let dock = slot.value {
            windowDockResourceKeys[ObjectIdentifier(dock)] =
                request.resourceKey
        }
    }

    private func popPendingRequest() -> PendingRequest? {
        if sealedRequests.isEmpty {
            sealPendingEventBatch()
        }
        return sealedRequests.popFirst()
    }

    private func activate(_ request: PendingRequest) -> Bool {
        let token = request.token
        let configuration = request.batchLineage.configuration
        let configuredRuntimePoints =
            configuration.configuredRuntimePoints
        let magnificationPercent =
            configuration.magnificationPercent
        switch request.target {
        case .workspace(let workspaceId, let workspaceReference):
            guard let workspace = attachedWorkspace(
                id: workspaceId,
                reference: workspaceReference
            ) else {
                return false
            }
            let fallbackLineage =
                request.batchLineage.didParticipateWindowDock
                ? request.windowDockPrefixChange.map {
                    $0.resultingInheritanceLineage(
                        from:
                            request.batchLineage
                                .windowDockSourceLineage,
                        configuredRuntimePoints:
                            configuredRuntimePoints,
                        magnificationPercent:
                            magnificationPercent
                    )
                }
                : nil
            let inheritanceContext =
                workspace.beginTerminalFontSizeChangeInheritance(
                    token: token,
                    change: request.change,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent,
                    fallbackLineage: fallbackLineage,
                    fallbackLineageAlreadyIncludesChange:
                        fallbackLineage != nil
                )
            let discovery =
                WorkspaceTerminalFontSizePanelDiscovery(
                    workspace: workspace
                )
#if DEBUG
            debugLastPanelDiscoveryConstructionVisitCount =
                discovery.debugConstructionVisitCount
#endif
            activeRequest = ActiveRequest(
                request: request,
                inheritanceContext: inheritanceContext,
                discovery: discovery,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
            return true

        case .windowDock(let dockSlot, let seedWorkspaceReference):
            let seedWorkspace: Workspace? = seedWorkspaceReference.flatMap {
                guard let workspace = $0.value else { return nil }
                return attachedWorkspace(
                    id: workspace.id,
                    reference: $0
                )
            }
            let previousLineage = dockSlot.pendingLineage
            let fallbackInheritanceContext =
                TerminalFontSizeChangeInheritanceContext(
                    token: token,
                    change: request.change,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent,
                    preferredSourcePanel: previousLineage == nil
                        ? seedWorkspace?
                            .lastRememberedTerminalPanelForConfigInheritance()
                        : nil,
                    fallbackLineage:
                        previousLineage
                        ?? seedWorkspace?
                            .lastRememberedTerminalFontSizeLineageForConfigInheritance()
                )
            let requestWindowDock = resolvedWindowDock(for: request)
            let inheritanceContext =
                requestWindowDock?.beginTerminalFontSizeChangeInheritance(
                    token: token,
                    change: request.change,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent: magnificationPercent,
                    fallbackLineage:
                        fallbackInheritanceContext.fallbackLineage,
                    fallbackLineageAlreadyIncludesChange: true
                )
                ?? fallbackInheritanceContext
            dockSlot.pendingInheritanceContext = inheritanceContext
            let discovery =
                WorkspaceTerminalFontSizePanelDiscovery(
                    windowDock: requestWindowDock
                )
#if DEBUG
            debugLastPanelDiscoveryConstructionVisitCount =
                discovery.debugConstructionVisitCount
#endif
            activeRequest = ActiveRequest(
                request: request,
                inheritanceContext: inheritanceContext,
                discovery: discovery,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
            return true
        }
    }

    private func resolvedWindowDock(
        for request: PendingRequest
    ) -> DockSplitStore? {
        windowDockSlot(for: request)?.value
    }

    private func windowDockSlot(
        for request: PendingRequest
    ) -> WindowDockSlot? {
        guard case .windowDock(let slot, _) = request.target else {
            return nil
        }
        return slot
    }

    func terminalWillLeaveWorkspace(
        _ terminalPanel: TerminalPanel,
        workspace: Workspace
    ) {
        guard workspace.terminalFontSizeChangeCoordinator === self else {
            return
        }
        sealPendingEventBatch()
        registerTransfer(
            terminalPanel,
            resourceKey: .workspace(workspace.id),
            processImmediately: false
        )
    }

    func terminalDidEnterWorkspace(
        _ terminalPanel: TerminalPanel,
        workspace: Workspace
    ) {
        guard workspace.terminalFontSizeChangeCoordinator === self else {
            return
        }
        sealPendingEventBatch()
        registerTransfer(
            terminalPanel,
            resourceKey: .workspace(workspace.id),
            processImmediately: true
        )
    }

    func terminalDidLeaveWorkspace(
        _ terminalPanel: TerminalPanel,
        workspace: Workspace,
        preservingTransfer: Bool = false
    ) {
        guard workspace.terminalFontSizeChangeCoordinator === self else {
            return
        }
        terminalDidLeave(
            terminalPanel,
            preservingTransfer: preservingTransfer
        )
    }

    func terminalWillLeaveDock(
        _ terminalPanel: TerminalPanel,
        dock: DockSplitStore
    ) {
        if let workspace = dock.terminalFontSizeOwningWorkspace {
            terminalWillLeaveWorkspace(
                terminalPanel,
                workspace: workspace
            )
            return
        }
        sealPendingEventBatch()
        guard let resourceKey =
                windowDockResourceKeys[ObjectIdentifier(dock)] else {
            return
        }
        registerTransfer(
            terminalPanel,
            resourceKey: resourceKey,
            processImmediately: false
        )
    }

    func terminalDidEnterDock(
        _ terminalPanel: TerminalPanel,
        dock: DockSplitStore
    ) {
        if let workspace = dock.terminalFontSizeOwningWorkspace {
            terminalDidEnterWorkspace(
                terminalPanel,
                workspace: workspace
            )
            return
        }
        sealPendingEventBatch()
        guard let resourceKey =
                windowDockResourceKeys[ObjectIdentifier(dock)] else {
            return
        }
        registerTransfer(
            terminalPanel,
            resourceKey: resourceKey,
            processImmediately: true
        )
    }

    func terminalDidLeaveDock(
        _ terminalPanel: TerminalPanel,
        dock: DockSplitStore,
        preservingTransfer: Bool = false
    ) {
        if let workspace = dock.terminalFontSizeOwningWorkspace {
            terminalDidLeaveWorkspace(
                terminalPanel,
                workspace: workspace,
                preservingTransfer: preservingTransfer
            )
            return
        }
        guard dock.terminalFontSizeChangeCoordinator === self else {
            return
        }
        terminalDidLeave(
            terminalPanel,
            preservingTransfer: preservingTransfer
        )
    }

    private func terminalDidLeave(
        _ terminalPanel: TerminalPanel,
        preservingTransfer: Bool
    ) {
        if !preservingTransfer {
            let abandonedObligations = transferObligations.filter {
                $0.panelId == terminalPanel.id
            }
            for obligation in abandonedObligations {
                removeTransferObligation(obligation)
            }
        }
        signalMutationRetry()
    }

    private func registerTransfer(
        _ terminalPanel: TerminalPanel,
        resourceKey: RequestResourceKey,
        processImmediately: Bool
    ) {
        signalMutationRetry(scheduleIfOutstanding: false)
#if DEBUG
        debugLastSynchronousTransferRequestVisitCount = 0
#endif
        guard let state = transferResourceStates[resourceKey],
              state.outstandingRequestCount > 0 else {
            return
        }
        guard let registration = state.register(
            panel: terminalPanel
        ) else {
            return
        }
        if registration.isNew {
            appendTransferObligation(registration.obligation)
        }
        let obligationSequence =
            registration.obligation.nextRequest?.request.sequence
        let shouldProcessImmediately =
            processImmediately
            || obligationSequence == earliestOutstandingRequestSequence
        if shouldProcessImmediately {
            drainTransferObligationsImmediately()
        } else {
            scheduleDrain(after: 0)
        }
    }

    private var earliestOutstandingRequestSequence: UInt64? {
        activeRequest?.request.sequence
            ?? sealedRequests.first?.sequence
    }

    private func appendTransferObligation(
        _ obligation: TransferObligation
    ) {
        nextTransferObligationOrder += 1
        obligation.heapOrder = nextTransferObligationOrder
        obligation.heapIndex = transferObligations.count
        transferObligations.append(obligation)
        siftTransferObligationUp(
            from: transferObligations.count - 1
        )
    }

    private func removeTransferObligation(
        _ obligation: TransferObligation
    ) {
        guard let index = obligation.heapIndex,
              transferObligations.indices.contains(index),
              transferObligations[index] === obligation else {
            obligation.resourceState?.remove(obligation)
            return
        }
        let lastIndex = transferObligations.count - 1
        if index != lastIndex {
            swapTransferObligations(at: index, lastIndex)
        }
        let removed = transferObligations.removeLast()
        removed.heapIndex = nil
        if index < transferObligations.count {
            repairTransferObligationHeap(at: index)
        }
        obligation.resourceState?.remove(obligation)
    }

    private func transferObligationPrecedes(
        _ lhs: TransferObligation,
        _ rhs: TransferObligation
    ) -> Bool {
        let lhsSequence =
            lhs.nextRequest?.request.sequence ?? UInt64.max
        let rhsSequence =
            rhs.nextRequest?.request.sequence ?? UInt64.max
        if lhsSequence != rhsSequence {
            return lhsSequence < rhsSequence
        }
        return lhs.heapOrder < rhs.heapOrder
    }

    private func swapTransferObligations(
        at lhs: Int,
        _ rhs: Int
    ) {
        transferObligations.swapAt(lhs, rhs)
        transferObligations[lhs].heapIndex = lhs
        transferObligations[rhs].heapIndex = rhs
    }

    private func siftTransferObligationUp(from startIndex: Int) {
        var index = startIndex
        while index > 0 {
            let parent = (index - 1) / 2
            guard transferObligationPrecedes(
                transferObligations[index],
                transferObligations[parent]
            ) else {
                return
            }
            swapTransferObligations(at: index, parent)
            index = parent
        }
    }

    private func siftTransferObligationDown(from startIndex: Int) {
        var index = startIndex
        while true {
            let left = index * 2 + 1
            guard left < transferObligations.count else { return }
            let right = left + 1
            var candidate = left
            if right < transferObligations.count,
               transferObligationPrecedes(
                    transferObligations[right],
                    transferObligations[left]
               ) {
                candidate = right
            }
            guard transferObligationPrecedes(
                transferObligations[candidate],
                transferObligations[index]
            ) else {
                return
            }
            swapTransferObligations(at: index, candidate)
            index = candidate
        }
    }

    private func repairTransferObligationHeap(at index: Int) {
        guard transferObligations.indices.contains(index) else { return }
        if index > 0 {
            let parent = (index - 1) / 2
            if transferObligationPrecedes(
                transferObligations[index],
                transferObligations[parent]
            ) {
                siftTransferObligationUp(from: index)
                return
            }
        }
        siftTransferObligationDown(from: index)
    }

    private func processOneTransferRequest(
        for obligation: TransferObligation,
        budget: inout WorkspaceTerminalFontSizeDrainBudget
    ) -> Bool {
        guard let requestRecord = obligation.nextRequest,
              let terminalPanel = obligation.panel else {
            removeTransferObligation(obligation)
            return true
        }
        guard budget.reserveRequestVisit(),
              budget.reservePanelVisit() else {
            return false
        }

        let request = requestRecord.request
        let alreadyIncludesChange = surfaceIncludesChange(
            on: terminalPanel,
            for: request
        )
        let sourceLineage =
            alreadyIncludesChange
            ? nil
            : terminalPanel.surface.fontSizeLineageForAdjustment(
                fallbackRuntimePoints:
                    requestRecord.configuredRuntimePoints,
                magnificationPercent:
                    requestRecord.magnificationPercent
            )
        let panelHasLiveSurface =
            terminalPanel.surface.hasLiveSurface
            && terminalPanel.surface.surface != nil
        if panelHasLiveSurface,
           !alreadyIncludesChange,
           !budget.reserveLiveActions(
                request.change.nativeActionUpperBoundPerLiveSurface
           ) {
            return false
        }

        var outcome: TerminalFontSizeMutationOutcome
        if !alreadyIncludesChange {
            outcome = applyChange(
                request.change,
                terminalPanel,
                requestRecord.configuredRuntimePoints,
                requestRecord.magnificationPercent
            )
        } else {
            outcome = .alreadySatisfied
        }
        outcome = reconciledMutationOutcome(
            outcome,
            terminalPanel: terminalPanel,
            sourceLineage: sourceLineage,
            request: request,
            configuredRuntimePoints:
                requestRecord.configuredRuntimePoints,
            magnificationPercent:
                requestRecord.magnificationPercent
        )
        guard outcome.didSucceed else {
            guard recordMutationFailure() else {
                discardActiveRequestPanelStorage()
                return false
            }
            Self.logger.error(
                "Skipping transferred terminal after repeated native font-size failure"
            )
            advanceTransferObligation(
                obligation,
                past: requestRecord
            )
            return true
        }
        recordMutationSuccess()
        if case .windowDock = request.target {
            request.batchLineage.didParticipateWindowDock = true
            if !alreadyIncludesChange {
                request.batchLineage
                    .windowDockSourceLineageSelection
                    .consider(
                        panelId: terminalPanel.id,
                        lineage: sourceLineage
                    )
            }
            request.batchLineage
                .windowDockLineageSelection
                .consider(
                    terminalPanel,
                    magnificationPercent:
                        requestRecord.magnificationPercent
                )
        }
        recordTransferredChange(
            on: terminalPanel,
            for: request
        )

        advanceTransferObligation(
            obligation,
            past: requestRecord
        )
        return true
    }

    private func advanceTransferObligation(
        _ obligation: TransferObligation,
        past requestRecord: TransferRequestRecord
    ) {
        let reachedEnd = requestRecord === obligation.throughRequest
        obligation.nextRequest = requestRecord.next
        if reachedEnd {
            removeTransferObligation(obligation)
        }
    }

    private func drainTransferObligationsImmediately() {
        guard !isDraining else {
            scheduleOutstandingContinuation()
            return
        }
        isDraining = true
        defer { isDraining = false }

        var budget = WorkspaceTerminalFontSizeDrainBudget()
        while let obligation = transferObligations.first,
              processOneTransferRequest(
                for: obligation,
                budget: &budget
              ) {
            if let index = obligation.heapIndex {
                repairTransferObligationHeap(at: index)
            }
        }
#if DEBUG
        debugLastSynchronousTransferRequestVisitCount =
            budget.requestVisitCount
#endif
        if !transferObligations.isEmpty {
            scheduleOutstandingContinuation()
        }
    }

    private func processNextTransferObligation(
        budget: inout WorkspaceTerminalFontSizeDrainBudget
    ) -> Bool {
        guard let obligation = transferObligations.first else {
            return false
        }
        guard processOneTransferRequest(
            for: obligation,
            budget: &budget
        ) else {
            return false
        }
        if let index = obligation.heapIndex {
            repairTransferObligationHeap(at: index)
        }
        return true
    }

    private func requestTransferToken(
        for request: PendingRequest
    ) -> UUID {
        switch request.target {
        case .workspace:
            return request.batchLineage.workspaceTransferToken
        case .windowDock:
            return request.batchLineage.windowDockTransferToken
        }
    }

    private func counterpartTransferToken(
        for request: PendingRequest
    ) -> UUID {
        switch request.target {
        case .workspace:
            return request.batchLineage.windowDockTransferToken
        case .windowDock:
            return request.batchLineage.workspaceTransferToken
        }
    }

    private func surfaceIncludesChange(
        on terminalPanel: TerminalPanel,
        for request: PendingRequest
    ) -> Bool {
        terminalPanel.surface.hasAppliedFontSizeChange(
            token: request.token
        )
            || terminalPanel.surface.hasAppliedFontSizeChange(
                token: counterpartTransferToken(for: request)
            )
    }

    /// Ghostty can update its logical font size before later native font work
    /// reports failure. Reconcile that observable target here so a relative
    /// request is never replayed against an already-advanced starting point.
    private func reconciledMutationOutcome(
        _ outcome: TerminalFontSizeMutationOutcome,
        terminalPanel: TerminalPanel,
        sourceLineage: TerminalFontSizeLineage?,
        request: PendingRequest,
        configuredRuntimePoints: Float32,
        magnificationPercent: Int
    ) -> TerminalFontSizeMutationOutcome {
        guard outcome == .failed else { return outcome }
        let expectedLineage =
            request.change.resultingInheritanceLineage(
                from: sourceLineage,
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
        guard let observedLineage =
                terminalPanel.surface.fontSizeLineageSnapshot(
                    magnificationPercent: magnificationPercent
                ),
              observedLineage.isExplicitOverride
                == expectedLineage.isExplicitOverride,
              abs(
                observedLineage.basePoints
                    - expectedLineage.basePoints
              ) < 0.000_1 else {
            return .failed
        }
        return .applied
    }

    private func recordAppliedChange(
        on terminalPanel: TerminalPanel,
        for request: PendingRequest
    ) {
        terminalPanel.surface.markFontSizeChangeApplied(
            token: request.token
        )
        terminalPanel.surface.markFontSizeChangeReconciledForTransfer(
            token: requestTransferToken(for: request)
        )
    }

    private func recordTransferredChange(
        on terminalPanel: TerminalPanel,
        for request: PendingRequest
    ) {
        terminalPanel.surface.markFontSizeChangeReconciledForTransfer(
            token: request.token
        )
        activeTransferRequestTokens.insert(request.token)
        terminalPanel.surface.markFontSizeChangeReconciledForTransfer(
            token: requestTransferToken(for: request)
        )
    }

    private func clearAllTransferReconciliationMarks() {
        for lineage in activeBatchLineages.values {
            TerminalSurface.clearFontSizeChangeReconciledForTransfer(
                token: lineage.windowDockTransferToken
            )
            TerminalSurface.clearFontSizeChangeReconciledForTransfer(
                token: lineage.workspaceTransferToken
            )
        }
        activeBatchLineages.removeAll(keepingCapacity: false)
        while let obligation = transferObligations.first {
            removeTransferObligation(obligation)
        }
        for token in activeTransferRequestTokens {
            TerminalSurface.clearFontSizeChangeReconciledForTransfer(
                token: token
            )
        }
        activeTransferRequestTokens.removeAll(keepingCapacity: false)
        transferResourceStates.removeAll(keepingCapacity: false)
        windowDockResourceKeys.removeAll(keepingCapacity: false)
    }

    private func retire(_ request: PendingRequest) {
        if activeTransferRequestTokens.remove(request.token) != nil {
            TerminalSurface.clearFontSizeChangeReconciledForTransfer(
                token: request.token
            )
        }
        if let resourceState =
                transferResourceStates[request.resourceKey],
           resourceState.retireRequest(token: request.token) {
            for obligation in Array(resourceState.obligations) {
                removeTransferObligation(obligation)
            }
            transferResourceStates.removeValue(
                forKey: request.resourceKey
            )
            if case .windowDock(let slot, _) = request.target,
               let dock = slot.value {
                let dockIdentity = ObjectIdentifier(dock)
                if windowDockResourceKeys[dockIdentity]
                    == request.resourceKey {
                    windowDockResourceKeys.removeValue(
                        forKey: dockIdentity
                    )
                }
            }
        }
        arbiter.promoteDeferredCoordinatorJoins()

        let batchLineage = request.batchLineage
        guard batchLineage.remainingRequestTokens.remove(request.token)
                != nil,
              batchLineage.remainingRequestTokens.isEmpty else {
            return
        }
        activeBatchLineages.removeValue(
            forKey: ObjectIdentifier(batchLineage)
        )
        TerminalSurface.clearFontSizeChangeReconciledForTransfer(
            token: batchLineage.windowDockTransferToken
        )
        TerminalSurface.clearFontSizeChangeReconciledForTransfer(
            token: batchLineage.workspaceTransferToken
        )
    }

    @discardableResult
    private func apply(
        _ candidate: WorkspaceTerminalFontSizePanelDiscovery.Candidate,
        terminalPanel: TerminalPanel,
        to activeRequest: inout ActiveRequest
    ) -> CoordinatedMutationDisposition {
        let alreadyIncludesChange = surfaceIncludesChange(
            on: terminalPanel,
            for: activeRequest.request
        )
        let sourceLineage =
            alreadyIncludesChange
            ? nil
            : terminalPanel.surface.fontSizeLineageForAdjustment(
                fallbackRuntimePoints:
                    activeRequest.configuredRuntimePoints,
                magnificationPercent:
                    activeRequest.magnificationPercent
            )
        var outcome: TerminalFontSizeMutationOutcome
        if !alreadyIncludesChange {
            outcome = applyChange(
                activeRequest.request.change,
                terminalPanel,
                activeRequest.configuredRuntimePoints,
                activeRequest.magnificationPercent
            )
        } else {
            outcome = .alreadySatisfied
        }
        outcome = reconciledMutationOutcome(
            outcome,
            terminalPanel: terminalPanel,
            sourceLineage: sourceLineage,
            request: activeRequest.request,
            configuredRuntimePoints:
                activeRequest.configuredRuntimePoints,
            magnificationPercent:
                activeRequest.magnificationPercent
        )
        guard outcome.didSucceed else {
            guard recordMutationFailure() else {
                activeRequest.discovery
                    .discardRetainedPanelStorage()
                return .retry
            }
            Self.logger.error(
                "Skipping terminal after repeated native font-size failure while config waits"
            )
            return .skipCandidate
        }
        recordMutationSuccess()
        recordAppliedChange(
            on: terminalPanel,
            for: activeRequest.request
        )

        activeRequest.participatingLineage.consider(
            terminalPanel,
            magnificationPercent:
                activeRequest.magnificationPercent
        )
        if case .windowDock = candidate.origin {
            activeRequest.request.batchLineage
                .didParticipateWindowDock = true
            if !alreadyIncludesChange {
                activeRequest.request.batchLineage
                    .windowDockSourceLineageSelection
                    .consider(
                        panelId: terminalPanel.id,
                        lineage: sourceLineage
                    )
            }
            activeRequest.request.batchLineage
                .windowDockLineageSelection
                .consider(
                    terminalPanel,
                    magnificationPercent:
                        activeRequest.magnificationPercent
                )
        }
        return .succeeded
    }

    private func finish(_ activeRequest: ActiveRequest) {
        defer {
            retireAndReleaseClaim(for: activeRequest.request)
        }
        switch activeRequest.request.target {
        case .workspace(let workspaceId, let workspaceReference):
            guard let workspace = attachedWorkspace(
                id: workspaceId,
                reference: workspaceReference
            ) else {
                workspaceReference.value?
                    .endTerminalFontSizeChangeInheritance(
                        token: activeRequest.token
                    )
                return
            }
            workspace.completeTerminalFontSizeChange(
                activeRequest.request.change,
                participatingLineage:
                    activeRequest.participatingLineage.lineage,
                configuredRuntimePoints:
                    activeRequest.configuredRuntimePoints,
                magnificationPercent:
                    activeRequest.magnificationPercent
            )
            workspace.endTerminalFontSizeChangeInheritance(
                token: activeRequest.token
            )

        case .windowDock(let dockSlot, _):
            let requestWindowDock = resolvedWindowDock(
                for: activeRequest.request
            )
            requestWindowDock?.endTerminalFontSizeChangeInheritance(
                token: activeRequest.token
            )
            dockSlot.clearPendingInheritanceContext(
                token: activeRequest.token
            )
            let finalLineage =
                activeRequest.request.batchLineage
                    .windowDockLineageSelection.lineage
                ?? activeRequest.inheritanceContext.fallbackLineage
            activeRequest.request.batchLineage
                .windowDockSourceLineage =
                activeRequest.request.batchLineage
                    .windowDockSourceLineageSelection.lineage
            if let requestWindowDock {
                requestWindowDock
                    .rememberTerminalFontSizeLineageForNewTerminals(
                        fallback: finalLineage,
                        magnificationPercent:
                            activeRequest.magnificationPercent
                    )
                dockSlot.pendingLineage = nil
            } else {
                dockSlot.pendingLineage =
                    finalLineage.isExplicitOverride
                    ? finalLineage
                    : nil
            }
        }
    }

    private func retireAndReleaseClaim(
        for request: PendingRequest
    ) {
        retire(request)
        if case .workspace(_, let workspaceReference) =
                request.target {
            releaseWorkspaceClaimIfIdle(
                workspaceReference.value
            )
        } else if case .windowDock = request.target {
            releaseWindowDockClaimIfIdle(
                windowDockSlot(for: request)
            )
        }
    }

    private func cancelInheritance(for activeRequest: ActiveRequest) {
        switch activeRequest.request.target {
        case .workspace(_, let workspaceReference):
            workspaceReference.value?
                .endTerminalFontSizeChangeInheritance(
                    token: activeRequest.token
                )
        case .windowDock(let dockSlot, _):
            resolvedWindowDock(for: activeRequest.request)?
                .endTerminalFontSizeChangeInheritance(
                    token: activeRequest.token
                )
            dockSlot.clearPendingInheritanceContext(
                token: activeRequest.token
            )
        }
    }

    private func resetMutationRetryState() {
        mutationRetryDisposition = .ready
        automaticMutationRetryAvailable = true
    }

    private func discardActiveRequestPanelStorage() {
        guard var activeRequest else { return }
        activeRequest.discovery.discardRetainedPanelStorage()
        self.activeRequest = activeRequest
    }

    func settleForFontSizeWorkIdleBarrier() {
        isSettlingForFontSizeWorkIdleBarrier = true
        mutationFailureCountSinceIdleBarrier = 0
        signalMutationRetry()
    }

    /// A new user request or terminal ownership transition is evidence that
    /// the failed native path may be viable again.
    func signalMutationRetry(
        scheduleIfOutstanding: Bool = true
    ) {
        let wasBlocked =
            mutationRetryDisposition != .ready
        if wasBlocked, scheduleIfOutstanding {
            invalidateScheduledDrain()
        }
        resetMutationRetryState()
        if wasBlocked, scheduleIfOutstanding {
            scheduleOutstandingContinuation()
        }
    }

    private func recordMutationSuccess() {
        mutationFailureCountSinceIdleBarrier = 0
        resetMutationRetryState()
    }

    @discardableResult
    private func recordMutationFailure() -> Bool {
        invalidateScheduledDrain()
        if isSettlingForFontSizeWorkIdleBarrier {
            mutationFailureCountSinceIdleBarrier += 1
            if mutationFailureCountSinceIdleBarrier >= 2 {
                mutationFailureCountSinceIdleBarrier = 0
                resetMutationRetryState()
                return true
            }
        }
        if automaticMutationRetryAvailable {
            automaticMutationRetryAvailable = false
            mutationRetryDisposition = .backoff
        } else {
            mutationRetryDisposition = .awaitingSignal
        }
        return false
    }

    func scheduleOutstandingContinuation(
        defaultDelay: TimeInterval = 0
    ) {
        guard activeRequest != nil || hasPendingRequests else { return }
        switch mutationRetryDisposition {
        case .ready:
            scheduleDrain(after: defaultDelay)
        case .backoff:
            scheduleDrain(
                after: Self.mutationRetryBackoffInterval
            )
        case .awaitingSignal:
            break
        }
    }

    private func scheduleDrain(after delay: TimeInterval) {
        guard cancelScheduledDrain == nil,
              activeRequest != nil || hasPendingRequests else {
            return
        }
        cancelScheduledDrain = schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelScheduledDrain = nil
            if self.mutationRetryDisposition == .backoff {
                self.mutationRetryDisposition = .ready
            }
            self.drain()
        }
    }

    private func invalidateScheduledDrain() {
        cancelScheduledDrain?()
        cancelScheduledDrain = nil
    }

    private func drain(scheduleContinuation: Bool = true) {
        guard !isDraining else {
            if scheduleContinuation {
                scheduleOutstandingContinuation()
            }
            return
        }
        isDraining = true
        defer { isDraining = false }

        var budget = WorkspaceTerminalFontSizeDrainBudget()
        var activeRequestHasBudgetReservation = false

        drainLoop: while true {
            if !transferObligations.isEmpty {
                guard processNextTransferObligation(
                    budget: &budget
                ) else {
                    break drainLoop
                }
                continue
            }

            if activeRequest == nil {
                while hasPendingRequests {
                    guard budget.reserveRequestVisit() else {
                        break drainLoop
                    }
                    guard let request = popPendingRequest() else {
                        break
                    }
                    guard activate(request) else {
                        retire(request)
                        if case .workspace(_, let workspaceReference) =
                                request.target {
                            releaseWorkspaceClaimIfIdle(
                                workspaceReference.value
                            )
                        } else if case .windowDock = request.target {
                            releaseWindowDockClaimIfIdle(
                                windowDockSlot(for: request)
                            )
                        }
                        continue
                    }
                    activeRequestHasBudgetReservation = true
                    break
                }
            }

            guard var current = activeRequest else { break }
            if !activeRequestHasBudgetReservation {
                guard budget.reserveRequestVisit() else {
                    break drainLoop
                }
                activeRequestHasBudgetReservation = true
            }

            let workspace: Workspace?
            let requestWindowDock: DockSplitStore?
            switch current.request.target {
            case .workspace(let workspaceId, let workspaceReference):
                guard let resolvedWorkspace = attachedWorkspace(
                    id: workspaceId,
                    reference: workspaceReference
                ) else {
                    activeRequest = nil
                    finish(current)
                    activeRequestHasBudgetReservation = false
                    continue
                }
                workspace = resolvedWorkspace
                requestWindowDock = nil
            case .windowDock:
                workspace = nil
                requestWindowDock = resolvedWindowDock(
                    for: current.request
                )
            }

            if let pendingCandidate = current.pendingCandidate {
                guard let pendingTerminalPanel =
                        pendingCandidate.mountedTerminalPanel(
                            in: workspace,
                            windowDock: requestWindowDock
                        ) else {
                    current.pendingCandidate = nil
                    current.seenPanelIds.remove(
                        pendingCandidate.panelId
                    )
                    activeRequest = current
                    continue
                }
                let alreadyIncludesChange = surfaceIncludesChange(
                    on: pendingTerminalPanel,
                    for: current.request
                )
                let panelHasLiveSurface =
                    pendingTerminalPanel.surface.hasLiveSurface
                    && pendingTerminalPanel.surface.surface != nil
                if panelHasLiveSurface,
                   !alreadyIncludesChange,
                   !budget.reserveLiveActions(
                        current.request.change
                            .nativeActionUpperBoundPerLiveSurface
                   ) {
                    activeRequest = current
                    break drainLoop
                }
                current.pendingCandidate = nil
                let disposition = apply(
                    pendingCandidate,
                    terminalPanel: pendingTerminalPanel,
                    to: &current
                )
                switch disposition {
                case .retry:
                    current.pendingCandidate = pendingCandidate
                    activeRequest = current
                    break drainLoop
                case .skipCandidate:
                    activeRequest = current
                case .succeeded:
                    activeRequest = current
                }
                continue
            }

            guard budget.reservePanelVisit() else {
                activeRequest = current
                break drainLoop
            }
            guard let visit = current.discovery.nextVisit(
                in: workspace,
                windowDock: requestWindowDock
            ) else {
                activeRequest = nil
                finish(current)
                activeRequestHasBudgetReservation = false
                continue
            }

            guard case .candidate(let candidate) = visit,
                  let terminalPanel =
                    candidate.mountedTerminalPanel(
                    in: workspace,
                    windowDock: requestWindowDock
                  ),
                  current.seenPanelIds.insert(
                    candidate.panelId
                  ).inserted
            else {
                activeRequest = current
                continue
            }

            let alreadyIncludesChange = surfaceIncludesChange(
                on: terminalPanel,
                for: current.request
            )
            let panelHasLiveSurface =
                terminalPanel.surface.hasLiveSurface
                && terminalPanel.surface.surface != nil
            if panelHasLiveSurface,
               !alreadyIncludesChange,
               !budget.reserveLiveActions(
                    current.request.change
                        .nativeActionUpperBoundPerLiveSurface
               ) {
                current.pendingCandidate = candidate
                activeRequest = current
                break drainLoop
            }

            switch apply(
                candidate,
                terminalPanel: terminalPanel,
                to: &current
            ) {
            case .retry:
                current.pendingCandidate = candidate
                activeRequest = current
                break drainLoop
            case .skipCandidate:
                activeRequest = current
            case .succeeded:
                activeRequest = current
            }
        }

        if scheduleContinuation,
           activeRequest != nil || hasPendingRequests {
            scheduleOutstandingContinuation()
        }
        releaseRetentionIfIdle()
    }
}

extension WorkspaceTerminalFontSizeChange {
    mutating func append(_ transform: TerminalFontSizeDeltaTransform) {
        switch self {
        case .relative(var existing):
            existing.append(contentsOf: transform)
            self = .relative(existing)
        case .resetThen(var existing):
            existing.append(contentsOf: transform)
            self = .resetThen(existing)
        }
    }
}
