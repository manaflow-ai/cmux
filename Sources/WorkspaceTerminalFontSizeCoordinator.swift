import Foundation
import CmuxFoundation
import CmuxTerminal
import CmuxTerminalCore

@MainActor
private struct WorkspaceTerminalFontSizePanelDiscovery {
    enum Origin {
        case workspace
        case workspaceDock
        case remoteMirror(mirrorId: UUID, paneId: Int)
        case windowDock
    }

    struct Candidate {
        let panel: TerminalPanel
        let origin: Origin

        @MainActor
        func isMounted(
            in workspace: Workspace?,
            windowDock: DockSplitStore?
        ) -> Bool {
            switch origin {
            case .workspace:
                return (workspace?.panels[panel.id] as? TerminalPanel) === panel
            case .workspaceDock:
                return (workspace?._dockSplit?.panels[panel.id]
                    as? TerminalPanel) === panel
            case .remoteMirror(let mirrorId, let paneId):
                return workspace?.remoteTmuxWindowMirror(forPanelId: mirrorId)?
                    .panelsByPaneId[paneId] === panel
            case .windowDock:
                return (windowDock?.panels[panel.id] as? TerminalPanel) === panel
            }
        }
    }

    enum Visit {
        case candidate(Candidate)
        case nonTerminal
    }

    private enum Phase {
        case workspace
        case workspaceDock
        case remoteMirrors
        case windowDock
        case finished
    }

    private var phase: Phase = .workspace
    private var workspacePanels: Dictionary<UUID, any Panel>.Iterator
    private var workspaceDockPanels:
        Dictionary<UUID, any Panel>.Iterator?
    private var remoteMirrors:
        Dictionary<UUID, RemoteTmuxWindowMirror>.Iterator
    private var remoteMirrorPanels:
        Dictionary<Int, TerminalPanel>.Iterator?
    private var remoteMirrorId: UUID?
    private var windowDockPanels:
        Dictionary<UUID, any Panel>.Iterator?

    init(workspace: Workspace) {
        workspacePanels = workspace.panels.makeIterator()
        workspaceDockPanels = workspace._dockSplit?.panels.makeIterator()
        remoteMirrors = workspace.remoteTmuxWindowMirrors.makeIterator()
        windowDockPanels = nil
    }

    init(windowDock: DockSplitStore?) {
        phase = .windowDock
        workspacePanels =
            Dictionary<UUID, any Panel>().makeIterator()
        workspaceDockPanels = nil
        remoteMirrors =
            Dictionary<UUID, RemoteTmuxWindowMirror>().makeIterator()
        windowDockPanels = windowDock?.panels.makeIterator()
    }

    mutating func nextVisit() -> Visit? {
        while true {
            switch phase {
            case .workspace:
                if let (_, panel) = workspacePanels.next() {
                    guard let terminalPanel = panel as? TerminalPanel else {
                        return .nonTerminal
                    }
                    return .candidate(
                        Candidate(panel: terminalPanel, origin: .workspace)
                    )
                }
                phase = .workspaceDock

            case .workspaceDock:
                if let (_, panel) = workspaceDockPanels?.next() {
                    guard let terminalPanel = panel as? TerminalPanel else {
                        return .nonTerminal
                    }
                    return .candidate(
                        Candidate(panel: terminalPanel, origin: .workspaceDock)
                    )
                }
                phase = .remoteMirrors

            case .remoteMirrors:
                if let (paneId, panel) = remoteMirrorPanels?.next(),
                   let remoteMirrorId {
                    return .candidate(
                        Candidate(
                            panel: panel,
                            origin: .remoteMirror(
                                mirrorId: remoteMirrorId,
                                paneId: paneId
                            )
                        )
                    )
                }
                remoteMirrorPanels = nil
                remoteMirrorId = nil
                if let (mirrorId, mirror) = remoteMirrors.next() {
                    remoteMirrorId = mirrorId
                    remoteMirrorPanels = mirror.panelsByPaneId.makeIterator()
                    return .nonTerminal
                }
                phase = .windowDock

            case .windowDock:
                if let (_, panel) = windowDockPanels?.next() {
                    guard let terminalPanel = panel as? TerminalPanel else {
                        return .nonTerminal
                    }
                    return .candidate(
                        Candidate(panel: terminalPanel, origin: .windowDock)
                    )
                }
                phase = .finished

            case .finished:
                return nil
            }
        }
    }
}
@MainActor
final class WorkspaceTerminalFontSizeCoordinator {
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
            Float32
        ) -> Bool

    private static let repeatCoalescingInterval: TimeInterval = 0.05

    private final class WeakWorkspaceReference {
        weak var value: Workspace?

        init(_ value: Workspace) {
            self.value = value
        }
    }

    /// Stable identity for one window's Dock, including the interval before
    /// its store is created. Requests keep the slot when workspace ownership
    /// forwards their execution to another window's coordinator.
    private final class WindowDockSlot {
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
        var windowDockSourceLineage: TerminalFontSizeLineage?
        var configuredRuntimePoints: Float32?
        var magnificationPercent: Int?
        var didParticipateWindowDock = false
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
        let target: RequestTarget
        let batchLineage: EventBatchLineage
        /// Ordered Dock changes through this workspace's most recent event.
        /// This is a constant-size value transform, not a panel snapshot.
        var windowDockPrefixChange: WorkspaceTerminalFontSizeChange?
        var change: WorkspaceTerminalFontSizeChange
    }

    private struct PendingEventBatch {
        let windowDockSlotIdentity: ObjectIdentifier
        let lineage: EventBatchLineage
        var windowDockRequest: PendingRequest
        var workspaceRequests: [UUID: PendingRequest] = [:]
        var workspaceOrder: [UUID] = []
    }

    /// An event that joins two independently busy coordinators waits here
    /// until either prior owner becomes available. The remaining owner then
    /// appends it to its ledger, preserving both resource orderings.
    private struct DeferredCoordinatorJoin {
        let workspaceId: UUID
        let workspaceReference: WeakWorkspaceReference
        let windowDockSlot: WindowDockSlot
        let preferredCoordinator:
            WorkspaceTerminalFontSizeCoordinator
        var change: WorkspaceTerminalFontSizeChange
        var deferFlush: Bool

        func matches(
            workspace: Workspace,
            windowDockSlot: WindowDockSlot
        ) -> Bool {
            workspaceId == workspace.id
                && workspaceReference.value === workspace
                && self.windowDockSlot === windowDockSlot
        }
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
        var windowDockSourceLineage = TerminalFontSizeLineageSelection()
        var windowDockLineage = TerminalFontSizeLineageSelection()
        var didVisitWindowDockTerminal = false
        let configuredRuntimePoints: Float32

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
    private var transferReconciledRequests: [UUID: PendingRequest] = [:]
    private let schedule: DrainScheduler
    private let applyChange: ChangeApplier
    private var cancelScheduledDrain: DrainCancellation?

    private static var deferredCoordinatorJoins:
        [DeferredCoordinatorJoin] = []
    private static var deferredCoordinatorJoinHead = 0
    private static var isPromotingDeferredCoordinatorJoins = false
    private static var isDeferredCoordinatorJoinPromotionScheduled = false
    private static var retainedCoordinators:
        [ObjectIdentifier: WorkspaceTerminalFontSizeCoordinator] = [:]

    init(
        tabManager: TabManager,
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
        applyChange: @escaping ChangeApplier = {
            change,
            terminalPanel,
            configuredRuntimePoints in
            cmuxApplyTerminalFontSizeChange(
                change,
                to: terminalPanel,
                configuredRuntimePoints: configuredRuntimePoints
            )
        }
    ) {
        self.tabManager = tabManager
        self.schedule = schedule
        self.applyChange = applyChange
    }

    func attachWindowDock(_ dock: DockSplitStore) {
        windowDockSlot.value = dock
        dock.terminalFontSizeChangeCoordinator =
            windowDockSlot.coordinator ?? self
        dock.terminalFontSizeOwningWorkspace = nil
        if let inheritanceContext =
                windowDockSlot.pendingInheritanceContext {
            dock.beginTerminalFontSizeChangeInheritance(
                token: inheritanceContext.token,
                change: inheritanceContext.change,
                configuredRuntimePoints:
                    inheritanceContext.configuredRuntimePoints,
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

    func enqueue(
        _ change: WorkspaceTerminalFontSizeChange,
        workspaceId: UUID,
        deferFlush: Bool
    ) {
        guard !change.isNoOp,
              let workspace = tabManager?.workspacesById[workspaceId] else {
            return
        }
        Self.promoteDeferredCoordinatorJoins()
        let workspaceReference = WeakWorkspaceReference(workspace)
        if Self.hasDeferredCoordinatorJoin(
            targeting: workspace,
            or: windowDockSlot
        ) {
            deferCoordinatorJoin(
                change,
                workspace: workspace,
                workspaceReference: workspaceReference,
                windowDockSlot: windowDockSlot,
                deferFlush: deferFlush
            )
            return
        }
        let workspaceCoordinator =
            coordinatorOwningWork(for: workspace)
        let windowDockCoordinator =
            coordinatorOwningWork(for: windowDockSlot)
        if let workspaceCoordinator,
           let windowDockCoordinator,
           workspaceCoordinator !== windowDockCoordinator {
            deferCoordinatorJoin(
                change,
                workspace: workspace,
                workspaceReference: workspaceReference,
                windowDockSlot: windowDockSlot,
                deferFlush: deferFlush
            )
            return
        }
        let eventCoordinator =
            workspaceCoordinator
            ?? windowDockCoordinator
            ?? self
        eventCoordinator.claimWorkspace(workspace)
        eventCoordinator.claimWindowDockSlot(windowDockSlot)
        eventCoordinator.appendEvent(
            change,
            workspaceId: workspaceId,
            workspaceReference: workspaceReference,
            windowDockSlot: windowDockSlot
        )
        eventCoordinator.flushOrSchedule(deferFlush: deferFlush)
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
        Self.removeDeferredCoordinatorJoins {
            $0.preferredCoordinator === self
        }
        windowDockSlot.pendingLineage = nil
        windowDockSlot.pendingInheritanceContext = nil
        Self.promoteDeferredCoordinatorJoins()
        releaseRetentionIfIdle()
    }

    /// Cancels work whose targets still belong to this closing window while
    /// allowing requests that followed moved workspaces or foreign Dock slots
    /// to finish on their surviving owners.
    func cancelWindowOwnedWork() {
        invalidateScheduledDrain()
        let closingManager = tabManager
        sealPendingEventBatch()

        var removedRequests: [PendingRequest] = []
        if let activeRequest,
           requestBelongsToClosingWindow(
                activeRequest.request,
                closingManager: closingManager
           ) {
            cancelInheritance(for: activeRequest)
            clearTransferReconciliationMarks(
                token: activeRequest.token
            )
            removedRequests.append(activeRequest.request)
            self.activeRequest = nil
        }
        removedRequests.append(
            contentsOf: sealedRequests.removeAll {
                requestBelongsToClosingWindow(
                    $0,
                    closingManager: closingManager
                )
            }
        )
        for request in removedRequests {
            clearTransferReconciliationMarks(token: request.token)
            releaseClaimIfIdle(for: request)
        }

        Self.removeDeferredCoordinatorJoins { join in
            guard join.preferredCoordinator === self else {
                return false
            }
            guard let workspace = join.workspaceReference.value else {
                return true
            }
            return workspace.owningTabManager === closingManager
        }
        if !hasOutstandingWork(for: windowDockSlot) {
            windowDockSlot.pendingLineage = nil
            windowDockSlot.pendingInheritanceContext = nil
            releaseWindowDockClaimIfIdle(windowDockSlot)
        }
        Self.promoteDeferredCoordinatorJoins()
        if activeRequest != nil || hasPendingRequests {
            retainWhileOutstanding()
            scheduleDrain(after: 0)
        } else {
            releaseRetentionIfIdle()
        }
    }

#if DEBUG
    func debugFlushOneDrain() {
        invalidateScheduledDrain()
        drain()
    }

    func debugDrainAll() {
        invalidateScheduledDrain()
        while activeRequest != nil || hasPendingRequests {
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
#endif

    private var hasPendingRequests: Bool {
        pendingEventBatch != nil || !sealedRequests.isEmpty
    }

    private func retainWhileOutstanding() {
        Self.retainedCoordinators[ObjectIdentifier(self)] = self
    }

    private func releaseRetentionIfIdle() {
        guard activeRequest == nil,
              !hasPendingRequests,
              !Self.hasDeferredCoordinatorJoin(
                preferredCoordinator: self
              ) else {
            return
        }
        Self.retainedCoordinators.removeValue(
            forKey: ObjectIdentifier(self)
        )
    }

    private func attachedWorkspace(
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

    private func coordinatorOwningWork(
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

    private func coordinatorOwningWork(
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
    ) {
        let lastIndex = Self.deferredCoordinatorJoins.indices.last
        if let lastIndex,
           lastIndex >= Self.deferredCoordinatorJoinHead,
           Self.deferredCoordinatorJoins[lastIndex].matches(
                workspace: workspace,
                windowDockSlot: windowDockSlot
           ) {
            var existing = Self.deferredCoordinatorJoins[lastIndex]
            append(change, to: &existing.change)
            existing.deferFlush = existing.deferFlush && deferFlush
            Self.deferredCoordinatorJoins[lastIndex] = existing
        } else {
            Self.deferredCoordinatorJoins.append(
                DeferredCoordinatorJoin(
                    workspaceId: workspace.id,
                    workspaceReference: workspaceReference,
                    windowDockSlot: windowDockSlot,
                    preferredCoordinator: self,
                    change: change,
                    deferFlush: deferFlush
                )
            )
        }
    }

    private static func promoteDeferredCoordinatorJoins() {
        guard !isPromotingDeferredCoordinatorJoins else { return }
        isPromotingDeferredCoordinatorJoins = true
        defer { isPromotingDeferredCoordinatorJoins = false }

        var joinVisitCount = 0
        while deferredCoordinatorJoinHead
                < deferredCoordinatorJoins.count,
              joinVisitCount
                < WorkspaceTerminalFontSizeDrainBudget
                    .maximumRequestVisitsPerDrain {
            let join =
                deferredCoordinatorJoins[deferredCoordinatorJoinHead]
            joinVisitCount += 1
            let preferred = join.preferredCoordinator
            guard let workspace = preferred.attachedWorkspace(
                id: join.workspaceId,
                reference: join.workspaceReference
            ) else {
                popDeferredCoordinatorJoin()
                preferred.releaseRetentionIfIdle()
                continue
            }
            let workspaceCoordinator =
                preferred.coordinatorOwningWork(for: workspace)
            let windowDockCoordinator =
                preferred.coordinatorOwningWork(
                    for: join.windowDockSlot
                )
            if let workspaceCoordinator,
               let windowDockCoordinator,
               workspaceCoordinator !== windowDockCoordinator {
                return
            }

            popDeferredCoordinatorJoin()
            let eventCoordinator =
                workspaceCoordinator
                ?? windowDockCoordinator
                ?? preferred
            eventCoordinator.claimWorkspace(workspace)
            eventCoordinator.claimWindowDockSlot(join.windowDockSlot)
            eventCoordinator.appendEvent(
                join.change,
                workspaceId: join.workspaceId,
                workspaceReference: join.workspaceReference,
                windowDockSlot: join.windowDockSlot
            )
            eventCoordinator.flushOrSchedule(
                deferFlush: join.deferFlush
            )
            preferred.releaseRetentionIfIdle()
        }
        if deferredCoordinatorJoinHead < deferredCoordinatorJoins.count {
            scheduleDeferredCoordinatorJoinPromotion()
        }
    }

    private static func scheduleDeferredCoordinatorJoinPromotion() {
        guard !isDeferredCoordinatorJoinPromotionScheduled else { return }
        isDeferredCoordinatorJoinPromotionScheduled = true
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                isDeferredCoordinatorJoinPromotionScheduled = false
                promoteDeferredCoordinatorJoins()
            }
        }
    }

    private static func popDeferredCoordinatorJoin() {
        deferredCoordinatorJoinHead += 1
        if deferredCoordinatorJoinHead == deferredCoordinatorJoins.count {
            deferredCoordinatorJoins.removeAll(keepingCapacity: false)
            deferredCoordinatorJoinHead = 0
        } else if deferredCoordinatorJoinHead >= 16,
                  deferredCoordinatorJoinHead * 2
                    >= deferredCoordinatorJoins.count {
            deferredCoordinatorJoins.removeFirst(
                deferredCoordinatorJoinHead
            )
            deferredCoordinatorJoinHead = 0
        }
    }

    private static func removeDeferredCoordinatorJoins(
        where shouldRemove: (DeferredCoordinatorJoin) -> Bool
    ) {
        let remaining = deferredCoordinatorJoins[
            deferredCoordinatorJoinHead...
        ].filter { !shouldRemove($0) }
        deferredCoordinatorJoins = Array(remaining)
        deferredCoordinatorJoinHead = 0
    }

    private static func hasDeferredCoordinatorJoin(
        preferredCoordinator: WorkspaceTerminalFontSizeCoordinator
    ) -> Bool {
        deferredCoordinatorJoins[
            deferredCoordinatorJoinHead...
        ].contains {
            $0.preferredCoordinator === preferredCoordinator
        }
    }

    private static func hasDeferredCoordinatorJoin(
        targeting workspace: Workspace,
        or windowDockSlot: WindowDockSlot
    ) -> Bool {
        deferredCoordinatorJoins[
            deferredCoordinatorJoinHead...
        ].contains {
            $0.workspaceReference.value === workspace
                || $0.windowDockSlot === windowDockSlot
        }
    }

    private func claimWorkspace(_ workspace: Workspace) {
        workspace.terminalFontSizeChangeCoordinator = self
        workspace._dockSplit?.terminalFontSizeChangeCoordinator = self
        workspace._dockSplit?.terminalFontSizeOwningWorkspace = workspace
    }

    private func claimWindowDockSlot(_ slot: WindowDockSlot) {
        slot.coordinator = self
        slot.value?.terminalFontSizeChangeCoordinator = self
        slot.value?.terminalFontSizeOwningWorkspace = nil
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
        closingManager: TabManager?
    ) -> Bool {
        switch request.target {
        case .workspace(_, let reference):
            guard let workspace = reference.value else { return true }
            return workspace.owningTabManager === closingManager
        case .windowDock(let slot, _):
            return slot === windowDockSlot
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
        Self.promoteDeferredCoordinatorJoins()
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
        Self.promoteDeferredCoordinatorJoins()
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

    private func flushOrSchedule(deferFlush: Bool) {
        if deferFlush {
            scheduleDrain(after: Self.repeatCoalescingInterval)
        } else {
            invalidateScheduledDrain()
            drain()
        }
    }

    private func appendEvent(
        _ change: WorkspaceTerminalFontSizeChange,
        workspaceId: UUID,
        workspaceReference: WeakWorkspaceReference,
        windowDockSlot: WindowDockSlot
    ) {
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
            let lineage = EventBatchLineage()
            let windowDockRequest = PendingRequest(
                token: UUID(),
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

        guard var batch = pendingEventBatch else { return }
        if var existing = batch.workspaceRequests[workspaceId] {
            append(change, to: &existing)
            existing.windowDockPrefixChange =
                batch.windowDockRequest.change
            batch.workspaceRequests[workspaceId] = existing
        } else {
            batch.workspaceOrder.append(workspaceId)
            batch.workspaceRequests[workspaceId] = PendingRequest(
                token: UUID(),
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
        sealedRequests.append(batch.windowDockRequest)
        for workspaceId in batch.workspaceOrder {
            guard let request = batch.workspaceRequests[workspaceId] else {
                continue
            }
            sealedRequests.append(request)
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
        switch request.target {
        case .workspace(let workspaceId, let workspaceReference):
            guard let workspace = attachedWorkspace(
                id: workspaceId,
                reference: workspaceReference
            ) else {
                return false
            }
            let configuredRuntimePoints =
                request.batchLineage.configuredRuntimePoints
                ?? workspace.configuredTerminalRuntimeFontSize()
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
                            request.batchLineage.magnificationPercent
                            ?? GlobalFontMagnification.storedPercent
                    )
                }
                : nil
            let inheritanceContext =
                workspace.beginTerminalFontSizeChangeInheritance(
                    token: token,
                    change: request.change,
                    configuredRuntimePoints: configuredRuntimePoints,
                    fallbackLineage: fallbackLineage,
                    fallbackLineageAlreadyIncludesChange:
                        fallbackLineage != nil
                )
            activeRequest = ActiveRequest(
                request: request,
                inheritanceContext: inheritanceContext,
                discovery: WorkspaceTerminalFontSizePanelDiscovery(
                    workspace: workspace
                ),
                configuredRuntimePoints: configuredRuntimePoints
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
            let configuredRuntimePoints =
                seedWorkspace?.configuredTerminalRuntimeFontSize()
                ?? currentConfiguredTerminalRuntimeFontSize()
            request.batchLineage.configuredRuntimePoints =
                configuredRuntimePoints
            request.batchLineage.magnificationPercent =
                GlobalFontMagnification.storedPercent
            let previousLineage = dockSlot.pendingLineage
            let inheritanceContext = TerminalFontSizeChangeInheritanceContext(
                token: token,
                change: request.change,
                configuredRuntimePoints: configuredRuntimePoints,
                preferredSourcePanel: previousLineage == nil
                    ? seedWorkspace?
                        .lastRememberedTerminalPanelForConfigInheritance()
                    : nil,
                fallbackLineage:
                    previousLineage
                    ?? seedWorkspace?
                        .lastRememberedTerminalFontSizeLineageForConfigInheritance()
            )
            dockSlot.pendingInheritanceContext = inheritanceContext
            let requestWindowDock = resolvedWindowDock(for: request)
            requestWindowDock?.beginTerminalFontSizeChangeInheritance(
                token: token,
                change: request.change,
                configuredRuntimePoints: configuredRuntimePoints,
                fallbackLineage: inheritanceContext.fallbackLineage,
                fallbackLineageAlreadyIncludesChange: true
            )
            activeRequest = ActiveRequest(
                request: request,
                inheritanceContext: inheritanceContext,
                discovery: WorkspaceTerminalFontSizePanelDiscovery(
                    windowDock: requestWindowDock
                ),
                configuredRuntimePoints: configuredRuntimePoints
            )
            return true
        }
    }

    private func currentConfiguredTerminalRuntimeFontSize() -> Float32 {
        Float32(
            GhosttyConfig.load(
                globalFontMagnificationPercent:
                    GlobalFontMagnification.storedPercent
            ).fontSize
        )
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
        reconcileTransfer(
            terminalPanel,
            requests: outstandingWorkspaceRequests(for: workspace),
            applyChanges: true
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
        reconcileTransfer(
            terminalPanel,
            requests: outstandingWorkspaceRequests(for: workspace),
            applyChanges: true
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
        guard dock === windowDock || hasOutstandingWork(for: dock) else {
            return
        }
        sealPendingEventBatch()
        reconcileTransfer(
            terminalPanel,
            requests: outstandingWindowDockRequests(for: dock),
            applyChanges: true
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
        guard dock === windowDock || hasOutstandingWork(for: dock) else {
            return
        }
        sealPendingEventBatch()
        reconcileTransfer(
            terminalPanel,
            requests: outstandingWindowDockRequests(for: dock),
            applyChanges: true
        )
    }

    private func outstandingWorkspaceRequests(
        for workspace: Workspace
    ) -> [(request: PendingRequest, configuredRuntimePoints: Float32)] {
        var requests: [
            (request: PendingRequest, configuredRuntimePoints: Float32)
        ] = []
        if let activeRequest,
           request(activeRequest.request, targets: workspace) {
            requests.append(
                (
                    request: activeRequest.request,
                    configuredRuntimePoints:
                        activeRequest.configuredRuntimePoints
                )
            )
        }
        let configuredRuntimePoints =
            workspace.configuredTerminalRuntimeFontSize()
        for request in sealedRequests.elements
        where self.request(request, targets: workspace) {
            requests.append(
                (
                    request: request,
                    configuredRuntimePoints: configuredRuntimePoints
                )
            )
        }
        if let request =
                pendingEventBatch?.workspaceRequests[workspace.id],
           self.request(request, targets: workspace) {
            requests.append(
                (
                    request: request,
                    configuredRuntimePoints: configuredRuntimePoints
                )
            )
        }
        return requests
    }

    private func outstandingWindowDockRequests(
        for dock: DockSplitStore
    )
        -> [(request: PendingRequest, configuredRuntimePoints: Float32)] {
        var requests: [
            (request: PendingRequest, configuredRuntimePoints: Float32)
        ] = []
        if let activeRequest,
           request(activeRequest.request, targets: dock) {
            requests.append(
                (
                    request: activeRequest.request,
                    configuredRuntimePoints:
                        activeRequest.configuredRuntimePoints
                )
            )
        }
        for request in sealedRequests.elements {
            guard self.request(request, targets: dock) else { continue }
            requests.append(
                (
                    request: request,
                    configuredRuntimePoints:
                        configuredRuntimePoints(for: request)
                )
            )
        }
        if let request = pendingEventBatch?.windowDockRequest,
           self.request(request, targets: dock) {
            requests.append(
                (
                    request: request,
                    configuredRuntimePoints:
                        configuredRuntimePoints(for: request)
                )
            )
        }
        return requests
    }

    private func configuredRuntimePoints(
        for request: PendingRequest
    ) -> Float32 {
        guard case .windowDock(_, let seedReference) = request.target,
              let seedReference,
              let workspace = seedReference.value else {
            return currentConfiguredTerminalRuntimeFontSize()
        }
        return workspace.configuredTerminalRuntimeFontSize()
    }

    private func reconcileTransfer(
        _ terminalPanel: TerminalPanel,
        requests: [
            (request: PendingRequest, configuredRuntimePoints: Float32)
        ],
        applyChanges: Bool
    ) {
        for entry in requests {
            if applyChanges,
               !transferReconciliation(
                    on: terminalPanel,
                    covers: entry.request
               ),
               !terminalPanel.surface.hasAppliedFontSizeChange(
                    token: entry.request.token
               ) {
                _ = applyChange(
                    entry.request.change,
                    terminalPanel,
                    entry.configuredRuntimePoints
                )
            }
            terminalPanel.surface
                .markFontSizeChangeReconciledForTransfer(
                    token: entry.request.token
                )
            transferReconciledRequests[entry.request.token] =
                entry.request
        }
    }

    private func transferReconciliation(
        on terminalPanel: TerminalPanel,
        covers request: PendingRequest
    ) -> Bool {
        for token in terminalPanel.surface
            .fontSizeChangeTokensForInheritance() {
            guard let reconciledRequest =
                    transferReconciledRequests[token] else {
                continue
            }
            if reconciledRequest.token == request.token {
                return true
            }
            guard reconciledRequest.batchLineage
                    === request.batchLineage else {
                continue
            }
            // One shortcut event is recorded in both the selected workspace
            // and Window Dock ledgers. Crossing that boundary must not replay
            // the shared event, while separate workspace ledgers stay distinct.
            switch (reconciledRequest.target, request.target) {
            case (.windowDock, .workspace),
                 (.workspace, .windowDock):
                return true
            default:
                continue
            }
        }
        return false
    }

    private func clearTransferReconciliationMarks(token: UUID) {
        guard transferReconciledRequests.removeValue(forKey: token)
                != nil else {
            return
        }
        TerminalSurface.clearFontSizeChangeReconciledForTransfer(
            token: token
        )
    }

    private func clearAllTransferReconciliationMarks() {
        let tokens = Array(transferReconciledRequests.keys)
        for token in tokens {
            clearTransferReconciliationMarks(token: token)
        }
    }

    private func apply(
        _ candidate: WorkspaceTerminalFontSizePanelDiscovery.Candidate,
        to activeRequest: inout ActiveRequest
    ) {
        let terminalPanel = candidate.panel
        if case .windowDock = candidate.origin {
            activeRequest.didVisitWindowDockTerminal = true
            activeRequest.windowDockSourceLineage.consider(terminalPanel)
        }
        let alreadyIncludesChange =
            terminalPanel.surface.hasAppliedFontSizeChange(
                token: activeRequest.token
            )
        if !alreadyIncludesChange {
            _ = applyChange(
                activeRequest.request.change,
                terminalPanel,
                activeRequest.configuredRuntimePoints
            )
            terminalPanel.surface.markFontSizeChangeApplied(
                token: activeRequest.token
            )
        }

        activeRequest.participatingLineage.consider(terminalPanel)
        if case .windowDock = candidate.origin {
            activeRequest.windowDockLineage.consider(terminalPanel)
        }
    }

    private func finish(_ activeRequest: ActiveRequest) {
        defer {
            clearTransferReconciliationMarks(
                token: activeRequest.token
            )
            if case .workspace(_, let workspaceReference) =
                    activeRequest.request.target {
                releaseWorkspaceClaimIfIdle(
                    workspaceReference.value
                )
            } else if case .windowDock =
                        activeRequest.request.target {
                releaseWindowDockClaimIfIdle(
                    windowDockSlot(for: activeRequest.request)
                )
            }
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
                    activeRequest.configuredRuntimePoints
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
                activeRequest.windowDockLineage.lineage
                ?? activeRequest.inheritanceContext.fallbackLineage
            activeRequest.request.batchLineage
                .windowDockSourceLineage =
                activeRequest.windowDockSourceLineage.lineage
            activeRequest.request.batchLineage
                .didParticipateWindowDock =
                activeRequest.didVisitWindowDockTerminal
            if let requestWindowDock {
                requestWindowDock
                    .rememberTerminalFontSizeLineageForNewTerminals(
                        fallback: finalLineage
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

    private func scheduleDrain(after delay: TimeInterval) {
        guard cancelScheduledDrain == nil,
              activeRequest != nil || hasPendingRequests else {
            return
        }
        cancelScheduledDrain = schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelScheduledDrain = nil
            self.drain()
        }
    }

    private func invalidateScheduledDrain() {
        cancelScheduledDrain?()
        cancelScheduledDrain = nil
    }

    private func drain(scheduleContinuation: Bool = true) {
        var budget = WorkspaceTerminalFontSizeDrainBudget()
        var activeRequestHasBudgetReservation = false

        drainLoop: while true {
            if activeRequest == nil {
                while hasPendingRequests {
                    guard budget.reserveRequestVisit() else {
                        break drainLoop
                    }
                    guard let request = popPendingRequest() else {
                        break
                    }
                    guard activate(request) else {
                        clearTransferReconciliationMarks(
                            token: request.token
                        )
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
                guard pendingCandidate.isMounted(
                    in: workspace,
                    windowDock: requestWindowDock
                ) else {
                    current.pendingCandidate = nil
                    current.seenPanelIds.remove(pendingCandidate.panel.id)
                    activeRequest = current
                    continue
                }
                let alreadyIncludesChange =
                    pendingCandidate.panel.surface.hasAppliedFontSizeChange(
                        token: current.token
                    )
                let panelHasLiveSurface =
                    pendingCandidate.panel.surface.hasLiveSurface
                    && pendingCandidate.panel.surface.surface != nil
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
                apply(
                    pendingCandidate,
                    to: &current
                )
                activeRequest = current
                continue
            }

            guard budget.reservePanelVisit() else {
                activeRequest = current
                break drainLoop
            }
            guard let visit = current.discovery.nextVisit() else {
                activeRequest = nil
                finish(current)
                activeRequestHasBudgetReservation = false
                continue
            }

            guard case .candidate(let candidate) = visit,
                  candidate.isMounted(
                    in: workspace,
                    windowDock: requestWindowDock
                  ),
                  current.seenPanelIds.insert(candidate.panel.id).inserted
            else {
                activeRequest = current
                continue
            }

            let alreadyIncludesChange =
                candidate.panel.surface.hasAppliedFontSizeChange(
                    token: current.token
                )
            let panelHasLiveSurface =
                candidate.panel.surface.hasLiveSurface
                && candidate.panel.surface.surface != nil
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

            apply(candidate, to: &current)
            activeRequest = current
        }

        if scheduleContinuation,
           activeRequest != nil || hasPendingRequests {
            scheduleDrain(after: 0)
        }
        releaseRetentionIfIdle()
    }
}

private extension WorkspaceTerminalFontSizeChange {
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
