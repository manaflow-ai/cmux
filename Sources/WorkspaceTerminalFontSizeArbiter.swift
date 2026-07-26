import Foundation

/// App-lifecycle owner for ordering work that spans window coordinators.
/// Production injects one instance into every window. Unit tests receive a
/// fresh instance by default unless they intentionally model two windows.
@MainActor
final class WorkspaceTerminalFontSizeArbiter {
    private typealias FontSizeWorkIdleAction =
        @MainActor () -> Void

    private enum PanelTransferDestinationKey: Hashable {
        case workspace(ObjectIdentifier)
        case windowDock(ObjectIdentifier)
    }

    private final class PanelTransferStage {
        let token = UUID()
        weak var coordinator:
            WorkspaceTerminalFontSizeCoordinator?
        weak var previous: PanelTransferStage?
        var next: PanelTransferStage?

        init(
            coordinator:
                WorkspaceTerminalFontSizeCoordinator
        ) {
            self.coordinator = coordinator
        }
    }

    private final class PanelTransferState {
        let handle: WorkspaceTerminalFontSizePanelTransfer
        var destination: PanelTransferDestinationKey?
        var stageHead: PanelTransferStage?
        var stageTail: PanelTransferStage?
        var stagesByToken: [UUID: PanelTransferStage] = [:]

        init(
            handle:
                WorkspaceTerminalFontSizePanelTransfer
        ) {
            self.handle = handle
        }

        func append(
            _ stage: PanelTransferStage
        ) {
            stage.previous = stageTail
            stageTail?.next = stage
            if stageHead == nil {
                stageHead = stage
            }
            stageTail = stage
            stagesByToken[stage.token] = stage
        }

        @discardableResult
        func remove(
            token: UUID
        ) -> Bool {
            guard let stage =
                    stagesByToken.removeValue(
                        forKey: token
                    ) else {
                return false
            }
            let previous = stage.previous
            let next = stage.next
            previous?.next = next
            next?.previous = previous
            if stageHead === stage {
                stageHead = next
            }
            if stageTail === stage {
                stageTail = previous
            }
            stage.previous = nil
            stage.next = nil
            return true
        }
    }

    private let maximumDeferredCoordinatorJoinCount: Int
    private var deferredCoordinatorJoins:
        [DeferredWorkspaceTerminalFontSizeCoordinatorJoin] = []
    private var deferredCoordinatorJoinHead = 0
    private var deferredCoordinatorJoinsAfterFontSizeWorkIdle:
        [DeferredWorkspaceTerminalFontSizeCoordinatorJoin] = []
    private var isPromotingDeferredCoordinatorJoins = false
    private var isCancellingWindowOwnedWork = false
    private var isDeferredCoordinatorJoinPromotionScheduled = false
    private var retainedCoordinators:
        [ObjectIdentifier: WorkspaceTerminalFontSizeCoordinator] = [:]
    private var panelTransferStates:
        [UUID: PanelTransferState] = [:]
    private var panelTransferDestinationCounts:
        [PanelTransferDestinationKey: Int] = [:]
    private var fontSizeWorkIdleActions:
        [FontSizeWorkIdleAction] = []
    private var fontSizeWorkIdleActionHead = 0
    private var isPerformingFontSizeWorkIdleActions = false
    private var extendedFontSizeWorkIdleBarrierTokens:
        Set<UUID> = []

    nonisolated init(
        maximumDeferredCoordinatorJoinCount: Int = 256
    ) {
        precondition(maximumDeferredCoordinatorJoinCount > 0)
        self.maximumDeferredCoordinatorJoinCount =
            maximumDeferredCoordinatorJoinCount
    }

    func retain(
        _ coordinator: WorkspaceTerminalFontSizeCoordinator
    ) {
        retainedCoordinators[ObjectIdentifier(coordinator)] =
            coordinator
    }

    func release(
        _ coordinator: WorkspaceTerminalFontSizeCoordinator
    ) {
        retainedCoordinators.removeValue(
            forKey: ObjectIdentifier(coordinator)
        )
        promoteDeferredCoordinatorJoins()
        performFontSizeWorkIdleActionsIfPossible()
    }

    func appendPanelTransferStage(
        panelId: UUID,
        existing:
            WorkspaceTerminalFontSizePanelTransfer?,
        coordinator:
            WorkspaceTerminalFontSizeCoordinator
    ) -> (
        handle: WorkspaceTerminalFontSizePanelTransfer,
        stageToken: UUID
    ) {
        let state: PanelTransferState
        if let existing,
           existing.panelId == panelId,
           let activeState =
                panelTransferStates[existing.id] {
            state = activeState
        } else {
            let handle =
                WorkspaceTerminalFontSizePanelTransfer(
                    panelId: panelId,
                    arbiter: self
                )
            state = PanelTransferState(handle: handle)
            panelTransferStates[handle.id] = state
        }
        let stage = PanelTransferStage(
            coordinator: coordinator
        )
        state.append(stage)
        return (state.handle, stage.token)
    }

    func isPanelTransferStageReady(
        _ handle:
            WorkspaceTerminalFontSizePanelTransfer,
        stageToken: UUID,
        coordinator:
            WorkspaceTerminalFontSizeCoordinator
    ) -> Bool {
        guard let state = panelTransferStates[handle.id],
              state.handle === handle,
              let head = state.stageHead else {
            return true
        }
        return head.token == stageToken
            && head.coordinator === coordinator
    }

    @discardableResult
    func completePanelTransferStage(
        _ handle:
            WorkspaceTerminalFontSizePanelTransfer,
        stageToken: UUID,
        coordinator:
            WorkspaceTerminalFontSizeCoordinator
    ) -> Bool {
        guard let state = panelTransferStates[handle.id],
              state.handle === handle,
              state.stagesByToken[stageToken]?
                .coordinator === coordinator,
              state.remove(token: stageToken) else {
            return !isPanelTransferActive(handle)
        }
        guard state.stageHead == nil else {
            signalRetainedCoordinators()
            return false
        }
        removePanelTransferState(state)
        signalRetainedCoordinators()
        promoteDeferredCoordinatorJoins()
        return true
    }

    func panelTransferCurrentCoordinator(
        _ handle:
            WorkspaceTerminalFontSizePanelTransfer
    ) -> WorkspaceTerminalFontSizeCoordinator? {
        panelTransferStates[handle.id]?
            .stageHead?
            .coordinator
    }

    func isPanelTransferActive(
        _ handle:
            WorkspaceTerminalFontSizePanelTransfer
    ) -> Bool {
        panelTransferStates[handle.id]?.handle === handle
    }

    func associatePanelTransfer(
        _ handle:
            WorkspaceTerminalFontSizePanelTransfer,
        with workspace: Workspace
    ) {
        associatePanelTransfer(
            handle,
            destination:
                .workspace(ObjectIdentifier(workspace))
        )
    }

    func associatePanelTransfer(
        _ handle:
            WorkspaceTerminalFontSizePanelTransfer,
        with windowDockSlot:
            WorkspaceTerminalFontSizeCoordinator.WindowDockSlot
    ) {
        guard let windowDock = windowDockSlot.value else {
            return
        }
        associatePanelTransfer(
            handle,
            with: windowDock
        )
    }

    func associatePanelTransfer(
        _ handle:
            WorkspaceTerminalFontSizePanelTransfer,
        with windowDock: DockSplitStore
    ) {
        associatePanelTransfer(
            handle,
            destination:
                .windowDock(
                    ObjectIdentifier(windowDock)
                )
        )
    }

    func hasPanelTransfer(
        targeting workspace: Workspace,
        or windowDockSlot:
            WorkspaceTerminalFontSizeCoordinator.WindowDockSlot
    ) -> Bool {
        panelTransferDestinationCounts[
            .workspace(ObjectIdentifier(workspace))
        ] != nil
            || windowDockSlot.value.map {
                panelTransferDestinationCounts[
                    .windowDock(ObjectIdentifier($0))
                ] != nil
            } == true
    }

    func signalPanelTransferProgress() {
        guard !panelTransferStates.isEmpty else { return }
        signalRetainedCoordinators()
    }

    private func associatePanelTransfer(
        _ handle:
            WorkspaceTerminalFontSizePanelTransfer,
        destination: PanelTransferDestinationKey
    ) {
        guard let state = panelTransferStates[handle.id],
              state.handle === handle,
              state.destination != destination else {
            return
        }
        if let previous = state.destination {
            decrementPanelTransferDestination(previous)
        }
        state.destination = destination
        panelTransferDestinationCounts[destination, default: 0]
            += 1
    }

    private func removePanelTransferState(
        _ state: PanelTransferState
    ) {
        guard panelTransferStates.removeValue(
            forKey: state.handle.id
        ) === state else {
            return
        }
        if let destination = state.destination {
            decrementPanelTransferDestination(destination)
        }
    }

    private func decrementPanelTransferDestination(
        _ destination: PanelTransferDestinationKey
    ) {
        guard let count =
                panelTransferDestinationCounts[
                    destination
                ] else {
            return
        }
        if count <= 1 {
            panelTransferDestinationCounts.removeValue(
                forKey: destination
            )
        } else {
            panelTransferDestinationCounts[destination] =
                count - 1
        }
    }

    /// Runs configuration work after every previously accepted font
    /// mutation. New mutations are retained behind the barrier so they
    /// observe the refreshed surface configuration.
    func performWhenFontSizeWorkIsIdle(
        _ action: @escaping @MainActor () -> Void
    ) {
        fontSizeWorkIdleActions.append(action)
        settleRetainedCoordinatorsForIdleBarrier()
        promoteDeferredCoordinatorJoins()
        performFontSizeWorkIdleActionsIfPossible()
    }

    /// Keeps post-barrier font input queued while asynchronous
    /// configuration reconciliation completes.
    func extendCurrentFontSizeWorkIdleBarrier()
        -> @MainActor () -> Void {
        precondition(
            isPerformingFontSizeWorkIdleActions,
            "Only an active idle action may extend its barrier"
        )
        let token = UUID()
        extendedFontSizeWorkIdleBarrierTokens.insert(token)
        return { [weak self] in
            guard let self,
                  self.extendedFontSizeWorkIdleBarrierTokens
                    .remove(token) != nil else {
                return
            }
            self.performFontSizeWorkIdleActionsIfPossible()
        }
    }

    @discardableResult
    func deferCoordinatorJoin(
        _ change: WorkspaceTerminalFontSizeChange,
        workspace: Workspace,
        workspaceReference: WorkspaceTerminalFontSizeCoordinator.WeakWorkspaceReference,
        windowDockSlot: WorkspaceTerminalFontSizeCoordinator.WindowDockSlot,
        preferredCoordinator:
            WorkspaceTerminalFontSizeCoordinator,
        deferFlush: Bool
    ) -> Bool {
        appendDeferredCoordinatorJoin(
            DeferredWorkspaceTerminalFontSizeCoordinatorJoin(
                workspaceId: workspace.id,
                workspaceReference: workspaceReference,
                windowDockSlot: windowDockSlot,
                preferredCoordinator: preferredCoordinator,
                change: change,
                deferFlush: deferFlush
            ),
            afterFontSizeWorkIdle: false
        )
    }

    /// Returns nil when no configuration barrier owns subsequent input.
    /// A non-nil result reports whether the bounded post-barrier queue
    /// accepted the change.
    func deferCoordinatorJoinAfterFontSizeWorkIdleIfNeeded(
        _ change: WorkspaceTerminalFontSizeChange,
        workspace: Workspace,
        workspaceReference: WorkspaceTerminalFontSizeCoordinator.WeakWorkspaceReference,
        windowDockSlot: WorkspaceTerminalFontSizeCoordinator.WindowDockSlot,
        preferredCoordinator:
            WorkspaceTerminalFontSizeCoordinator,
        deferFlush: Bool
    ) -> Bool? {
        guard hasFontSizeWorkIdleBarrier else { return nil }
        let accepted = appendDeferredCoordinatorJoin(
            DeferredWorkspaceTerminalFontSizeCoordinatorJoin(
                workspaceId: workspace.id,
                workspaceReference: workspaceReference,
                windowDockSlot: windowDockSlot,
                preferredCoordinator: preferredCoordinator,
                change: change,
                deferFlush: deferFlush
            ),
            afterFontSizeWorkIdle: true
        )
        signalRetainedCoordinators()
        return accepted
    }

    func promoteDeferredCoordinatorJoins() {
        guard !isPromotingDeferredCoordinatorJoins,
              !isCancellingWindowOwnedWork else {
            return
        }
        isPromotingDeferredCoordinatorJoins = true
        defer {
            isPromotingDeferredCoordinatorJoins = false
            performFontSizeWorkIdleActionsIfPossible()
        }

        var joinVisitCount = 0
        while deferredCoordinatorJoinHead
                < deferredCoordinatorJoins.count,
              joinVisitCount
                < WorkspaceTerminalFontSizeDrainBudget
                    .maximumRequestVisitsPerDrain {
            let join =
                deferredCoordinatorJoins[
                    deferredCoordinatorJoinHead
                ]
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
            if hasPanelTransfer(
                targeting: workspace,
                or: join.windowDockSlot
            ) {
                return
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

            let eventCoordinator =
                workspaceCoordinator
                ?? windowDockCoordinator
                ?? preferred
            eventCoordinator.signalMutationRetry(
                scheduleIfOutstanding: false
            )
            guard eventCoordinator.appendEvent(
                join.change,
                workspaceId: join.workspaceId,
                workspaceReference: join.workspaceReference,
                windowDockSlot: join.windowDockSlot
            ) else {
                eventCoordinator.scheduleOutstandingContinuation()
                return
            }
            popDeferredCoordinatorJoin()
            eventCoordinator.claimWorkspace(workspace)
            eventCoordinator.claimWindowDockSlot(
                join.windowDockSlot
            )
            eventCoordinator.flushOrSchedule(
                deferFlush: join.deferFlush
            )
            preferred.releaseRetentionIfIdle()
        }
        if deferredCoordinatorJoinHead
                < deferredCoordinatorJoins.count {
            scheduleDeferredCoordinatorJoinPromotion()
        }
    }

    func cancelWindowOwnedWork(
        requestedBy requester:
            WorkspaceTerminalFontSizeCoordinator,
        closingManager: TabManager?,
        closingWindowDockSlot:
            WorkspaceTerminalFontSizeCoordinator.WindowDockSlot
    ) {
        guard !isCancellingWindowOwnedWork else { return }
        isCancellingWindowOwnedWork = true
        defer {
            isCancellingWindowOwnedWork = false
            promoteDeferredCoordinatorJoins()
        }

        removeDeferredCoordinatorJoins { join in
            let workspaceIsClosing =
                closingManager != nil
                && join.workspaceReference.value?
                    .owningTabManager === closingManager
            return workspaceIsClosing
                || join.windowDockSlot === closingWindowDockSlot
        }

        var coordinators = retainedCoordinators
        coordinators[ObjectIdentifier(requester)] = requester
        for coordinator in coordinators.values {
            coordinator.cancelWork(
                targeting: closingManager,
                windowDockSlot: closingWindowDockSlot
            )
        }
    }

    func removeDeferredCoordinatorJoins(
        preferredCoordinator:
            WorkspaceTerminalFontSizeCoordinator
    ) {
        removeDeferredCoordinatorJoins {
            $0.preferredCoordinator === preferredCoordinator
        }
    }

    private func removeDeferredCoordinatorJoins(
        where shouldRemove:
            (DeferredWorkspaceTerminalFontSizeCoordinatorJoin) -> Bool
    ) {
        let remaining = deferredCoordinatorJoins[
            deferredCoordinatorJoinHead...
        ].filter { !shouldRemove($0) }
        deferredCoordinatorJoins = Array(remaining)
        deferredCoordinatorJoinHead = 0
        deferredCoordinatorJoinsAfterFontSizeWorkIdle.removeAll(
            where: shouldRemove
        )
        performFontSizeWorkIdleActionsIfPossible()
    }

    func hasDeferredCoordinatorJoin(
        preferredCoordinator:
            WorkspaceTerminalFontSizeCoordinator
    ) -> Bool {
        deferredCoordinatorJoins[
            deferredCoordinatorJoinHead...
        ].contains {
            $0.preferredCoordinator === preferredCoordinator
        }
    }

    func hasDeferredCoordinatorJoin(
        targeting workspace: Workspace,
        or windowDockSlot: WorkspaceTerminalFontSizeCoordinator.WindowDockSlot
    ) -> Bool {
        deferredCoordinatorJoins[
            deferredCoordinatorJoinHead...
        ].contains {
            $0.workspaceReference.value === workspace
                || $0.windowDockSlot === windowDockSlot
        }
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

    private var deferredCoordinatorJoinCount: Int {
        deferredCoordinatorJoins.count
            - deferredCoordinatorJoinHead
    }

    private var totalDeferredCoordinatorJoinCount: Int {
        deferredCoordinatorJoinCount
            + deferredCoordinatorJoinsAfterFontSizeWorkIdle.count
    }

    private var hasPendingFontSizeWorkIdleActions: Bool {
        fontSizeWorkIdleActionHead < fontSizeWorkIdleActions.count
    }

    private var hasFontSizeWorkIdleBarrier: Bool {
        hasPendingFontSizeWorkIdleActions
            || isPerformingFontSizeWorkIdleActions
            || !extendedFontSizeWorkIdleBarrierTokens.isEmpty
            || !deferredCoordinatorJoinsAfterFontSizeWorkIdle.isEmpty
    }

    private var isFontSizeWorkIdleBeforeBarrier: Bool {
        retainedCoordinators.isEmpty
            && deferredCoordinatorJoinCount == 0
            && !isPromotingDeferredCoordinatorJoins
            && !isCancellingWindowOwnedWork
            && extendedFontSizeWorkIdleBarrierTokens.isEmpty
    }

    @discardableResult
    private func appendDeferredCoordinatorJoin(
        _ join: DeferredWorkspaceTerminalFontSizeCoordinatorJoin,
        afterFontSizeWorkIdle: Bool
    ) -> Bool {
        if afterFontSizeWorkIdle {
            if let lastIndex =
                    deferredCoordinatorJoinsAfterFontSizeWorkIdle
                        .indices.last,
               let workspace = join.workspaceReference.value,
               deferredCoordinatorJoinsAfterFontSizeWorkIdle[
                    lastIndex
               ].matches(
                    workspace: workspace,
                    windowDockSlot: join.windowDockSlot
               ) {
                var existing =
                    deferredCoordinatorJoinsAfterFontSizeWorkIdle[
                        lastIndex
                    ]
                append(join.change, to: &existing.change)
                existing.deferFlush =
                    existing.deferFlush && join.deferFlush
                deferredCoordinatorJoinsAfterFontSizeWorkIdle[
                    lastIndex
                ] = existing
                return true
            }
        } else if let lastIndex =
                    deferredCoordinatorJoins.indices.last,
                  lastIndex >= deferredCoordinatorJoinHead,
                  let workspace = join.workspaceReference.value,
                  deferredCoordinatorJoins[lastIndex].matches(
                    workspace: workspace,
                    windowDockSlot: join.windowDockSlot
                  ) {
            var existing = deferredCoordinatorJoins[lastIndex]
            append(join.change, to: &existing.change)
            existing.deferFlush =
                existing.deferFlush && join.deferFlush
            deferredCoordinatorJoins[lastIndex] = existing
            return true
        }

        // Preserve every accepted join's order, but stop accepting new
        // distinct pairs once blocked owners fill the bounded backlog.
        // Adjacent repeats above still coalesce into constant-size
        // transforms at the limit.
        guard totalDeferredCoordinatorJoinCount
                < maximumDeferredCoordinatorJoinCount else {
            return false
        }
        if afterFontSizeWorkIdle {
            deferredCoordinatorJoinsAfterFontSizeWorkIdle.append(join)
        } else {
            deferredCoordinatorJoins.append(join)
        }
        return true
    }

    private func signalRetainedCoordinators() {
        let coordinators = Array(retainedCoordinators.values)
        for coordinator in coordinators {
            coordinator.signalMutationRetry()
        }
    }

    private func settleRetainedCoordinatorsForIdleBarrier() {
        let coordinators = Array(retainedCoordinators.values)
        for coordinator in coordinators {
            coordinator.settleForFontSizeWorkIdleBarrier()
        }
    }

    private func popFontSizeWorkIdleAction()
        -> FontSizeWorkIdleAction? {
        guard hasPendingFontSizeWorkIdleActions else { return nil }
        let action =
            fontSizeWorkIdleActions[fontSizeWorkIdleActionHead]
        fontSizeWorkIdleActionHead += 1
        if fontSizeWorkIdleActionHead
                == fontSizeWorkIdleActions.count {
            fontSizeWorkIdleActions.removeAll(keepingCapacity: false)
            fontSizeWorkIdleActionHead = 0
        } else if fontSizeWorkIdleActionHead >= 16,
                  fontSizeWorkIdleActionHead * 2
                    >= fontSizeWorkIdleActions.count {
            fontSizeWorkIdleActions.removeFirst(
                fontSizeWorkIdleActionHead
            )
            fontSizeWorkIdleActionHead = 0
        }
        return action
    }

    private func performFontSizeWorkIdleActionsIfPossible() {
        guard !isPerformingFontSizeWorkIdleActions,
              isFontSizeWorkIdleBeforeBarrier else {
            return
        }

        if hasPendingFontSizeWorkIdleActions {
            isPerformingFontSizeWorkIdleActions = true
            while isFontSizeWorkIdleBeforeBarrier,
                  let action = popFontSizeWorkIdleAction() {
                action()
            }
            isPerformingFontSizeWorkIdleActions = false
        }

        guard isFontSizeWorkIdleBeforeBarrier,
              !hasPendingFontSizeWorkIdleActions,
              !deferredCoordinatorJoinsAfterFontSizeWorkIdle
                .isEmpty else {
            return
        }
        deferredCoordinatorJoins.append(
            contentsOf:
                deferredCoordinatorJoinsAfterFontSizeWorkIdle
        )
        deferredCoordinatorJoinsAfterFontSizeWorkIdle.removeAll(
            keepingCapacity: false
        )
        promoteDeferredCoordinatorJoins()
    }

    private func scheduleDeferredCoordinatorJoinPromotion() {
        guard !isDeferredCoordinatorJoinPromotionScheduled else {
            return
        }
        isDeferredCoordinatorJoinPromotionScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDeferredCoordinatorJoinPromotionScheduled =
                    false
                self.promoteDeferredCoordinatorJoins()
            }
        }
    }

    private func popDeferredCoordinatorJoin() {
        deferredCoordinatorJoinHead += 1
        if deferredCoordinatorJoinHead
                == deferredCoordinatorJoins.count {
            deferredCoordinatorJoins.removeAll(
                keepingCapacity: false
            )
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
}
