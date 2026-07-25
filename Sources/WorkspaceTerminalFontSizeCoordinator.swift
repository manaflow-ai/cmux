import Foundation
import CmuxFoundation
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

    private static let repeatCoalescingInterval: TimeInterval = 0.05

    private final class WeakWorkspaceReference {
        weak var value: Workspace?

        init(_ value: Workspace) {
            self.value = value
        }
    }

    private final class WeakTerminalPanelReference {
        weak var value: TerminalPanel?

        init(_ value: TerminalPanel) {
            self.value = value
        }
    }

    private enum RequestTarget {
        case workspace(
            id: UUID,
            reference: WeakWorkspaceReference
        )
        case windowDock(
            seedWorkspace: WeakWorkspaceReference?
        )
    }

    private struct PendingRequest {
        let token: UUID
        let target: RequestTarget
        let fallbackSourceIdentity: ObjectIdentifier?
        let fallbackSourceLineage: TerminalFontSizeLineage?
        var resultingFallbackLineage: TerminalFontSizeLineage?
        var change: WorkspaceTerminalFontSizeChange
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
    }

    private struct ActiveRequest {
        let request: PendingRequest
        let inheritanceContext: TerminalFontSizeChangeInheritanceContext
        var discovery: WorkspaceTerminalFontSizePanelDiscovery
        var pendingCandidate:
            WorkspaceTerminalFontSizePanelDiscovery.Candidate?
        var seenPanelIds: Set<UUID> = []
        var participatingLineage = TerminalFontSizeLineageSelection()
        var windowDockLineage = TerminalFontSizeLineageSelection()
        let configuredRuntimePoints: Float32

        var token: UUID {
            request.token
        }
    }

    private weak var tabManager: TabManager?
    private weak var windowDock: DockSplitStore?
    private var pendingWindowDockLineage: TerminalFontSizeLineage?
    private var pendingWindowDockInheritanceContext:
        TerminalFontSizeChangeInheritanceContext?

    private var pendingWorkspaceRequests: [UUID: PendingRequest] = [:]
    private var pendingWindowDockRequest: PendingRequest?
    private var sealedWorkspaceRequests = PendingRequestQueue()
    private var sealedWindowDockRequests = PendingRequestQueue()
    private var activeRequest: ActiveRequest?
    private var transferReconciledPanelsByToken:
        [UUID: [UUID: WeakTerminalPanelReference]] = [:]
    private let schedule: DrainScheduler
    private var cancelScheduledDrain: DrainCancellation?

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
        }
    ) {
        self.tabManager = tabManager
        self.schedule = schedule
    }

    func attachWindowDock(_ dock: DockSplitStore) {
        windowDock = dock
        dock.terminalFontSizeChangeCoordinator = self
        dock.terminalFontSizeOwningWorkspace = nil
        if let inheritanceContext = pendingWindowDockInheritanceContext {
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
                fallback: pendingWindowDockLineage
            )
        }
        pendingWindowDockLineage = nil
        pendingWindowDockInheritanceContext = nil
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
        let workspaceReference = WeakWorkspaceReference(workspace)
        let fallbackSourceIdentity = windowDock.map(ObjectIdentifier.init)
        let fallbackSourceLineage =
            windowDock?.terminalFontSizeLineageForWorkspaceChange()
        let workspaceCoordinator = coordinatorOwningWork(
            for: workspace
        ) ?? self
        workspaceCoordinator.claimWorkspace(workspace)
        workspaceCoordinator.appendWorkspaceRequest(
            change,
            workspaceId: workspaceId,
            workspaceReference: workspaceReference,
            fallbackSourceIdentity: fallbackSourceIdentity,
            fallbackSourceLineage: fallbackSourceLineage
        )
        appendWindowDockRequest(
            change,
            seedWorkspaceReference: workspaceReference
        )
        if workspaceCoordinator === self {
            flushOrSchedule(deferFlush: deferFlush)
        } else {
            workspaceCoordinator.flushOrSchedule(
                deferFlush: deferFlush
            )
            flushOrSchedule(deferFlush: deferFlush)
        }
    }

    func cancelAll() {
        invalidateScheduledDrain()
        if let activeRequest {
            cancelInheritance(for: activeRequest)
        }
        clearAllTransferReconciliationMarks()
        releaseAllWorkspaceClaims()
        activeRequest = nil
        pendingWorkspaceRequests.removeAll(keepingCapacity: false)
        pendingWindowDockRequest = nil
        sealedWorkspaceRequests.removeAll()
        sealedWindowDockRequests.removeAll()
        pendingWindowDockLineage = nil
        pendingWindowDockInheritanceContext = nil
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
        pendingWorkspaceRequests.count
            + sealedWorkspaceRequests.count
            + (activeRequest == nil ? 0 : 1)
    }
#endif

    private var hasPendingRequests: Bool {
        !pendingWorkspaceRequests.isEmpty
            || pendingWindowDockRequest != nil
            || !sealedWorkspaceRequests.isEmpty
            || !sealedWindowDockRequests.isEmpty
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

    private func claimWorkspace(_ workspace: Workspace) {
        workspace.terminalFontSizeChangeCoordinator = self
        workspace._dockSplit?.terminalFontSizeChangeCoordinator = self
        workspace._dockSplit?.terminalFontSizeOwningWorkspace = workspace
    }

    private func hasOutstandingWork(for workspace: Workspace) -> Bool {
        if let activeRequest,
           request(activeRequest.request, targets: workspace) {
            return true
        }
        if let request = pendingWorkspaceRequests[workspace.id],
           self.request(request, targets: workspace) {
            return true
        }
        return sealedWorkspaceRequests.elements.contains {
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

    private func releaseWorkspaceClaimIfIdle(_ workspace: Workspace?) {
        guard let workspace,
              workspace.terminalFontSizeChangeCoordinator === self,
              !hasOutstandingWork(for: workspace) else {
            return
        }
        workspace.terminalFontSizeChangeCoordinator = nil
    }

    private func releaseAllWorkspaceClaims() {
        var workspacesByIdentity: [ObjectIdentifier: Workspace] = [:]
        func collect(_ request: PendingRequest) {
            guard case .workspace(_, let reference) = request.target,
                  let workspace = reference.value else {
                return
            }
            workspacesByIdentity[ObjectIdentifier(workspace)] = workspace
        }
        if let activeRequest {
            collect(activeRequest.request)
        }
        pendingWorkspaceRequests.values.forEach(collect)
        sealedWorkspaceRequests.elements.forEach(collect)
        for workspace in workspacesByIdentity.values
        where workspace.terminalFontSizeChangeCoordinator === self {
            workspace.terminalFontSizeChangeCoordinator = nil
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

    private func appendWorkspaceRequest(
        _ change: WorkspaceTerminalFontSizeChange,
        workspaceId: UUID,
        workspaceReference: WeakWorkspaceReference,
        fallbackSourceIdentity: ObjectIdentifier?,
        fallbackSourceLineage: TerminalFontSizeLineage?
    ) {
        if var existing = pendingWorkspaceRequests[workspaceId] {
            guard existing.fallbackSourceIdentity
                    == fallbackSourceIdentity,
                  existing.fallbackSourceLineage
                    == fallbackSourceLineage else {
                sealWorkspaceRequest(workspaceId: workspaceId)
                appendWorkspaceRequest(
                    change,
                    workspaceId: workspaceId,
                    workspaceReference: workspaceReference,
                    fallbackSourceIdentity: fallbackSourceIdentity,
                    fallbackSourceLineage: fallbackSourceLineage
                )
                return
            }
            append(change, to: &existing)
            if let resultingFallbackLineage =
                    existing.resultingFallbackLineage {
                existing.resultingFallbackLineage =
                    change.resultingInheritanceLineage(
                        from: resultingFallbackLineage,
                        configuredRuntimePoints:
                            workspaceReference.value?
                                .configuredTerminalRuntimeFontSize()
                            ?? currentConfiguredTerminalRuntimeFontSize(),
                        magnificationPercent:
                            GlobalFontMagnification.storedPercent
                    )
            }
            pendingWorkspaceRequests[workspaceId] = existing
            return
        }
        let configuredRuntimePoints =
            workspaceReference.value?
                .configuredTerminalRuntimeFontSize()
            ?? currentConfiguredTerminalRuntimeFontSize()
        pendingWorkspaceRequests[workspaceId] = PendingRequest(
            token: UUID(),
            target: .workspace(
                id: workspaceId,
                reference: workspaceReference
            ),
            fallbackSourceIdentity: fallbackSourceIdentity,
            fallbackSourceLineage: fallbackSourceLineage,
            resultingFallbackLineage: fallbackSourceLineage.map {
                change.resultingInheritanceLineage(
                    from: $0,
                    configuredRuntimePoints: configuredRuntimePoints,
                    magnificationPercent:
                        GlobalFontMagnification.storedPercent
                )
            },
            change: change
        )
    }

    private func appendWindowDockRequest(
        _ change: WorkspaceTerminalFontSizeChange,
        seedWorkspaceReference: WeakWorkspaceReference
    ) {
        if var existing = pendingWindowDockRequest {
            append(change, to: &existing)
            pendingWindowDockRequest = existing
            return
        }
        pendingWindowDockRequest = PendingRequest(
            token: UUID(),
            target: .windowDock(
                seedWorkspace: seedWorkspaceReference
            ),
            fallbackSourceIdentity: nil,
            fallbackSourceLineage: nil,
            resultingFallbackLineage: nil,
            change: change
        )
    }

    private func append(
        _ change: WorkspaceTerminalFontSizeChange,
        to request: inout PendingRequest
    ) {
        switch change {
        case .relative(let transform):
            request.change.append(transform)
        case .resetThen(let transform):
            request.change.appendReset()
            request.change.append(transform)
        }
    }

    private func sealWorkspaceRequest(workspaceId: UUID) {
        guard let request = pendingWorkspaceRequests.removeValue(
            forKey: workspaceId
        ) else {
            return
        }
        sealedWorkspaceRequests.append(request)
    }

    private func sealWindowDockRequest() {
        guard let request = pendingWindowDockRequest else {
            return
        }
        pendingWindowDockRequest = nil
        sealedWindowDockRequests.append(request)
    }

    private func popPendingRequest() -> PendingRequest? {
        // Establish the window-Dock inheritance result before a bounded
        // workspace scan can span another event-loop turn. A Dock created
        // during that scan then inherits the pending result exactly once.
        if let request = sealedWindowDockRequests.popFirst() {
            return request
        }
        if let request = pendingWindowDockRequest {
            pendingWindowDockRequest = nil
            return request
        }
        if let request = sealedWorkspaceRequests.popFirst() {
            return request
        }
        if let workspaceId = pendingWorkspaceRequests.keys.first {
            return pendingWorkspaceRequests.removeValue(
                forKey: workspaceId
            )
        }
        return nil
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
                workspace.configuredTerminalRuntimeFontSize()
            let inheritanceContext =
                workspace.beginTerminalFontSizeChangeInheritance(
                    token: token,
                    change: request.change,
                    configuredRuntimePoints: configuredRuntimePoints,
                    fallbackLineage:
                        request.resultingFallbackLineage,
                    fallbackLineageAlreadyIncludesChange:
                        request.resultingFallbackLineage != nil
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

        case .windowDock(let seedWorkspaceReference):
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
            let previousLineage = pendingWindowDockLineage
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
            pendingWindowDockInheritanceContext = inheritanceContext
            windowDock?.beginTerminalFontSizeChangeInheritance(
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
                    windowDock: windowDock
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

    func terminalWillLeaveWorkspace(
        _ terminalPanel: TerminalPanel,
        workspace: Workspace
    ) {
        guard workspace.terminalFontSizeChangeCoordinator === self else {
            return
        }
        sealWorkspaceRequest(workspaceId: workspace.id)
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
        sealWorkspaceRequest(workspaceId: workspace.id)
        reconcileTransfer(
            terminalPanel,
            requests: outstandingWorkspaceRequests(for: workspace),
            applyChanges: false
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
        guard dock === windowDock else { return }
        sealWindowDockRequest()
        reconcileTransfer(
            terminalPanel,
            requests: outstandingWindowDockRequests(),
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
        guard dock === windowDock else { return }
        sealWindowDockRequest()
        reconcileTransfer(
            terminalPanel,
            requests: outstandingWindowDockRequests(),
            applyChanges: false
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
        for request in sealedWorkspaceRequests.elements
        where self.request(request, targets: workspace) {
            requests.append(
                (
                    request: request,
                    configuredRuntimePoints: configuredRuntimePoints
                )
            )
        }
        if let request = pendingWorkspaceRequests[workspace.id],
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

    private func outstandingWindowDockRequests()
        -> [(request: PendingRequest, configuredRuntimePoints: Float32)] {
        var requests: [
            (request: PendingRequest, configuredRuntimePoints: Float32)
        ] = []
        if let activeRequest,
           case .windowDock = activeRequest.request.target {
            requests.append(
                (
                    request: activeRequest.request,
                    configuredRuntimePoints:
                        activeRequest.configuredRuntimePoints
                )
            )
        }
        for request in sealedWindowDockRequests.elements {
            requests.append(
                (
                    request: request,
                    configuredRuntimePoints:
                        configuredRuntimePoints(for: request)
                )
            )
        }
        if let request = pendingWindowDockRequest {
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
        guard case .windowDock(let seedReference) = request.target,
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
               !terminalPanel.surface.hasAppliedFontSizeChange(
                    token: entry.request.token
               ) {
                _ = cmuxApplyTerminalFontSizeChange(
                    entry.request.change,
                    to: terminalPanel,
                    configuredRuntimePoints:
                        entry.configuredRuntimePoints
                )
            }
            terminalPanel.surface
                .markFontSizeChangeReconciledForTransfer(
                    token: entry.request.token
                )
            var panels =
                transferReconciledPanelsByToken[entry.request.token] ?? [:]
            panels[terminalPanel.id] =
                WeakTerminalPanelReference(terminalPanel)
            transferReconciledPanelsByToken[entry.request.token] = panels
        }
    }

    private func clearTransferReconciliationMarks(token: UUID) {
        guard let panels =
                transferReconciledPanelsByToken.removeValue(
                    forKey: token
                ) else {
            return
        }
        for reference in panels.values {
            reference.value?.surface
                .clearFontSizeChangeReconciledForTransfer(token: token)
        }
    }

    private func clearAllTransferReconciliationMarks() {
        let tokens = Array(transferReconciledPanelsByToken.keys)
        for token in tokens {
            clearTransferReconciliationMarks(token: token)
        }
    }

    private func apply(
        _ candidate: WorkspaceTerminalFontSizePanelDiscovery.Candidate,
        to activeRequest: inout ActiveRequest
    ) {
        let terminalPanel = candidate.panel
        let alreadyIncludesChange =
            terminalPanel.surface.hasAppliedFontSizeChange(
                token: activeRequest.token
            )
        if !alreadyIncludesChange {
            _ = cmuxApplyTerminalFontSizeChange(
                activeRequest.request.change,
                to: terminalPanel,
                configuredRuntimePoints:
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

        case .windowDock:
            windowDock?.endTerminalFontSizeChangeInheritance(
                token: activeRequest.token
            )
            clearPendingWindowDockContext(
                token: activeRequest.token
            )
            let finalLineage =
                activeRequest.windowDockLineage.lineage
                ?? activeRequest.inheritanceContext.fallbackLineage
            if let windowDock {
                windowDock.rememberTerminalFontSizeLineageForNewTerminals(
                    fallback: finalLineage
                )
            } else {
                pendingWindowDockLineage =
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
        case .windowDock:
            windowDock?.endTerminalFontSizeChangeInheritance(
                token: activeRequest.token
            )
            clearPendingWindowDockContext(
                token: activeRequest.token
            )
        }
    }

    private func clearPendingWindowDockContext(token: UUID) {
        guard pendingWindowDockInheritanceContext?.token == token else {
            return
        }
        pendingWindowDockInheritanceContext = nil
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
            case .windowDock:
                workspace = nil
            }

            if let pendingCandidate = current.pendingCandidate {
                guard pendingCandidate.isMounted(
                    in: workspace,
                    windowDock: windowDock
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
                    windowDock: windowDock
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
