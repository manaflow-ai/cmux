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
            in workspace: Workspace,
            windowDock: DockSplitStore?
        ) -> Bool {
            switch origin {
            case .workspace:
                return (workspace.panels[panel.id] as? TerminalPanel) === panel
            case .workspaceDock:
                return (workspace._dockSplit?.panels[panel.id]
                    as? TerminalPanel) === panel
            case .remoteMirror(let mirrorId, let paneId):
                return workspace.remoteTmuxWindowMirror(forPanelId: mirrorId)?
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

    init(workspace: Workspace, windowDock: DockSplitStore?) {
        workspacePanels = workspace.panels.makeIterator()
        workspaceDockPanels = workspace._dockSplit?.panels.makeIterator()
        remoteMirrors = workspace.remoteTmuxWindowMirrors.makeIterator()
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

    private struct PendingRequest {
        let workspaceId: UUID
        var change: WorkspaceTerminalFontSizeChange
    }

    private struct ActiveRequest {
        let request: PendingRequest
        let workspaceReference: WeakWorkspaceReference
        let token: UUID
        var discovery: WorkspaceTerminalFontSizePanelDiscovery
        var pendingCandidate:
            WorkspaceTerminalFontSizePanelDiscovery.Candidate?
        var seenPanelIds: Set<UUID> = []
        var participatingLineage = TerminalFontSizeLineageSelection()
        var windowDockLineage = TerminalFontSizeLineageSelection()
        let configuredRuntimePoints: Float32
    }

    private weak var tabManager: TabManager?
    private weak var windowDock: DockSplitStore?
    private var pendingWindowDockLineage: TerminalFontSizeLineage?
    private var pendingWindowDockInheritanceContext:
        TerminalFontSizeChangeInheritanceContext?

    private var pendingRequests: [PendingRequest] = []
    private var pendingRequestHead = 0
    private var activeRequest: ActiveRequest?
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
        guard !change.isNoOp else { return }
        append(
            PendingRequest(workspaceId: workspaceId, change: change)
        )
        if deferFlush {
            scheduleDrain(after: Self.repeatCoalescingInterval)
        } else {
            invalidateScheduledDrain()
            drain()
        }
    }

    func cancelAll() {
        invalidateScheduledDrain()
        if let activeRequest {
            activeRequest.workspaceReference.value?
                .endTerminalFontSizeChangeInheritance(
                    token: activeRequest.token
                )
            windowDock?.endTerminalFontSizeChangeInheritance(
                token: activeRequest.token
            )
        }
        activeRequest = nil
        pendingRequests.removeAll(keepingCapacity: false)
        pendingRequestHead = 0
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
        pendingRequestCount + (activeRequest == nil ? 0 : 1)
    }
#endif

    private var hasPendingRequests: Bool {
        pendingRequestHead < pendingRequests.count
    }

    private var pendingRequestCount: Int {
        pendingRequests.count - pendingRequestHead
    }

    private func resolveWorkspace(_ workspaceId: UUID) -> Workspace? {
        tabManager?.tabs.first { $0.id == workspaceId }
    }

    private func append(_ request: PendingRequest) {
        guard hasPendingRequests,
              let lastIndex = pendingRequests.indices.last,
              pendingRequests[lastIndex].workspaceId == request.workspaceId
        else {
            pendingRequests.append(request)
            return
        }

        switch request.change {
        case .relative(let transform):
            pendingRequests[lastIndex].change.append(transform)
        case .resetThen(let transform):
            pendingRequests[lastIndex].change.appendReset()
            pendingRequests[lastIndex].change.append(transform)
        }
    }

    private func popPendingRequest() -> PendingRequest? {
        guard hasPendingRequests else { return nil }
        let request = pendingRequests[pendingRequestHead]
        pendingRequestHead += 1
        if pendingRequestHead == pendingRequests.count {
            pendingRequests.removeAll(keepingCapacity: true)
            pendingRequestHead = 0
        } else if pendingRequestHead >= 64,
                  pendingRequestHead * 2 >= pendingRequests.count {
            pendingRequests.removeFirst(pendingRequestHead)
            pendingRequestHead = 0
        }
        return request
    }

    private func activate(_ request: PendingRequest) -> Bool {
        guard let workspace = resolveWorkspace(request.workspaceId) else {
            return false
        }

        let configuredRuntimePoints =
            workspace.configuredTerminalRuntimeFontSize()
        let token = UUID()
        let inheritanceContext =
            workspace.beginTerminalFontSizeChangeInheritance(
                token: token,
                change: request.change,
                configuredRuntimePoints: configuredRuntimePoints
            )

        if let windowDock {
            windowDock.beginTerminalFontSizeChangeInheritance(
                token: token,
                change: request.change,
                configuredRuntimePoints: configuredRuntimePoints,
                fallbackLineage: inheritanceContext.fallbackLineage,
                fallbackLineageAlreadyIncludesChange: true
            )
        } else {
            let previousLineage = pendingWindowDockLineage
            let pendingContext = TerminalFontSizeChangeInheritanceContext(
                token: token,
                change: request.change,
                configuredRuntimePoints: configuredRuntimePoints,
                preferredSourcePanel: nil,
                fallbackLineage:
                    previousLineage ?? inheritanceContext.fallbackLineage,
                fallbackLineageAlreadyIncludesChange:
                    previousLineage == nil
            )
            pendingWindowDockLineage = pendingContext.fallbackLineage
            pendingWindowDockInheritanceContext = pendingContext
        }

        activeRequest = ActiveRequest(
            request: request,
            workspaceReference: WeakWorkspaceReference(workspace),
            token: token,
            discovery: WorkspaceTerminalFontSizePanelDiscovery(
                workspace: workspace,
                windowDock: windowDock
            ),
            configuredRuntimePoints: configuredRuntimePoints
        )
        return true
    }

    private func apply(
        _ candidate: WorkspaceTerminalFontSizePanelDiscovery.Candidate,
        to activeRequest: inout ActiveRequest,
        workspace: Workspace
    ) {
        let terminalPanel = candidate.panel
        let alreadyIncludesChange =
            terminalPanel.surface.hasAppliedFontSizeChange(
                token: activeRequest.token
            )
        if !alreadyIncludesChange {
            _ = workspace.applyTerminalFontSizeChange(
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
        guard let workspace = resolveWorkspace(
            activeRequest.request.workspaceId
        ), workspace === activeRequest.workspaceReference.value else {
            activeRequest.workspaceReference.value?
                .endTerminalFontSizeChangeInheritance(
                    token: activeRequest.token
                )
            windowDock?.endTerminalFontSizeChangeInheritance(
                token: activeRequest.token
            )
            clearPendingWindowDockContext(token: activeRequest.token)
            return
        }

        workspace.completeTerminalFontSizeChange(
            activeRequest.request.change,
            participatingLineage: activeRequest.participatingLineage.lineage,
            configuredRuntimePoints: activeRequest.configuredRuntimePoints
        )
        workspace.endTerminalFontSizeChangeInheritance(
            token: activeRequest.token
        )
        windowDock?.endTerminalFontSizeChangeInheritance(
            token: activeRequest.token
        )
        clearPendingWindowDockContext(token: activeRequest.token)

        if let windowDock {
            windowDock.rememberTerminalFontSizeLineageForNewTerminals(
                fallback:
                    activeRequest.windowDockLineage.lineage
                    ?? workspace
                        .lastRememberedTerminalFontSizeLineageForConfigInheritance()
            )
        } else if pendingWindowDockLineage == nil {
            pendingWindowDockLineage =
                workspace
                    .lastRememberedTerminalFontSizeLineageForConfigInheritance()
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
                    guard activate(request) else { continue }
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

            guard let workspace = resolveWorkspace(
                current.request.workspaceId
            ), workspace === current.workspaceReference.value else {
                activeRequest = nil
                finish(current)
                activeRequestHasBudgetReservation = false
                continue
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
                    to: &current,
                    workspace: workspace
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

            apply(candidate, to: &current, workspace: workspace)
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
