import Foundation

enum TerminalLifecycleExecutorAction: String, Codable, Sendable {
    case noop
    case waitForAnchor
    case bindVisible
    case moveToDetachedRetained
    case moveToParkedOffscreen
    case destroy
}

struct TerminalLifecycleExecutorBindingSnapshot: Codable, Sendable {
    let panelId: UUID
    let anchorId: UUID?
    let windowNumber: Int?
    let anchorWindowNumber: Int?
    let visibleInUI: Bool
    let hostedHidden: Bool
    let attachedToPortalHost: Bool
    let zPriority: Int
    let guardGeneration: UInt64?
    let guardState: String
}

struct TerminalLifecycleExecutorBindingCounts: Codable, Sendable {
    let panelCount: Int
    let visibleEntryCount: Int
    let hiddenEntryCount: Int
    let attachedEntryCount: Int
    let currentGenerationCount: Int
}

struct TerminalLifecycleExecutorRecordSnapshot: Codable, Sendable {
    let panelId: UUID
    let workspaceId: UUID
    let generation: UInt64
    let action: TerminalLifecycleExecutorAction
    let currentState: PanelLifecycleState
    let targetState: PanelLifecycleState
    let currentResidency: PanelResidency
    let targetResidency: PanelResidency
    let currentVisible: Bool
    let targetVisible: Bool
    let currentActive: Bool
    let targetActive: Bool
    let requiresCurrentGenerationAnchor: Bool
    let anchorReadyForVisibility: Bool
    let targetWindowNumber: Int?
    let targetAnchorId: UUID?
    let bindingPresent: Bool
    let bindingSatisfied: Bool
    let bindingAnchorId: UUID?
    let bindingWindowNumber: Int?
    let bindingVisibleInUI: Bool?
    let bindingHostedHidden: Bool?
    let bindingAttachedToPortalHost: Bool?
    let bindingGeneration: UInt64?
    let bindingState: String?
}

struct TerminalLifecycleExecutorPlanCounts: Codable, Sendable {
    let panelCount: Int
    let noopCount: Int
    let waitForAnchorCount: Int
    let bindVisibleCount: Int
    let moveToDetachedRetainedCount: Int
    let moveToParkedOffscreenCount: Int
    let destroyCount: Int
}

struct TerminalLifecycleExecutorPlanSnapshot: Codable, Sendable {
    let counts: TerminalLifecycleExecutorPlanCounts
    let bindingCounts: TerminalLifecycleExecutorBindingCounts
    let bindings: [TerminalLifecycleExecutorBindingSnapshot]
    let records: [TerminalLifecycleExecutorRecordSnapshot]
}

struct TerminalLifecycleExecutorRuntimeDecision: Sendable {
    let action: TerminalLifecycleExecutorAction
    let bindingSatisfied: Bool
    let shouldSynchronizeVisibleGeometry: Bool

    var shouldAdvanceSynchronizedGeometryRevision: Bool {
        action == .bindVisible || shouldSynchronizeVisibleGeometry
    }
}

struct TerminalLifecycleExecutorRuntimeTarget: Sendable {
    let targetResidency: PanelResidency
    let targetVisible: Bool
    let targetActive: Bool
    let targetWindowNumber: Int?
    let targetAnchorId: UUID?
    let requiresCurrentGenerationAnchor: Bool
    let anchorReadyForVisibility: Bool
    let decision: TerminalLifecycleExecutorRuntimeDecision

    var shouldMountLiveAnchor: Bool {
        targetResidency == .visibleInActiveWindow
    }
}

struct TerminalLifecycleExecutorRuntimeApplicationPlan: Sendable {
    let decision: TerminalLifecycleExecutorRuntimeDecision
    let shouldUpdateEntryVisibility: Bool
    let entryVisibleInUI: Bool
    let shouldSynchronizeForAnchor: Bool
    let shouldBindVisible: Bool
    let shouldDetachHostedView: Bool
    let shouldUnmountHostedView: Bool
}

struct TerminalLifecycleExecutorHostedStateApplicationPlan: Sendable {
    let shouldApplyImmediately: Bool
    let visibleInUI: Bool
    let active: Bool
}

struct TerminalLifecycleExecutorHostedViewSnapshot: Sendable {
    let hasSuperview: Bool
    let inWindow: Bool
    let hidden: Bool
    let hasUsableGeometry: Bool
    let hasSurface: Bool
}

struct TerminalLifecycleExecutorRecoveryDecision: Sendable {
    let shouldRequestViewReattach: Bool
    let shouldRequestBackgroundSurfaceStart: Bool

    var shouldScheduleGeometryReconcile: Bool {
        shouldRequestViewReattach || shouldRequestBackgroundSurfaceStart
    }
}

struct TerminalLifecycleExecutorVisibilityTransitionDecision: Sendable {
    let shouldPreserveVisibleOnTransientLoss: Bool
    let shouldDeferReveal: Bool
    let shouldRevealHostedView: Bool
}

struct TerminalLifecycleExecutorFrameApplicationPlan: Sendable {
    let shouldHide: Bool
    let shouldDeferReveal: Bool
    let transientRecoveryReason: TerminalLifecycleExecutorTransientRecoveryReason?
    let transientRetryDirective: TerminalLifecycleExecutorTransientRetryDirective
    let hiddenStateAction: TerminalLifecycleExecutorHiddenStateAction
    let visibilityTransition: TerminalLifecycleExecutorVisibilityTransitionDecision
}

enum TerminalLifecycleExecutorGeometryRefreshReason: String, Sendable {
    case portalFrameChange = "portal.frameChange"
    case portalReveal = "portal.reveal"
    case portalExternalGeometrySync = "portal.externalGeometrySync"
}

struct TerminalLifecycleExecutorFrameGeometryApplicationPlan: Sendable {
    let shouldApplyFrame: Bool
    let shouldApplyBounds: Bool
    let shouldReconcileGeometry: Bool
    let refreshReason: TerminalLifecycleExecutorGeometryRefreshReason?
}

struct TerminalLifecycleExecutorRevealApplicationPlan: Sendable {
    let shouldRevealHostedView: Bool
    let shouldReconcileGeometry: Bool
    let refreshReason: TerminalLifecycleExecutorGeometryRefreshReason?
}

struct TerminalLifecycleExecutorBindSeedPlan: Sendable {
    let frame: NSRect
    let bounds: NSRect
    let shouldHideHostedView: Bool
    let shouldReconcileGeometry: Bool
}

struct TerminalLifecycleExecutorExternalGeometryApplicationPlan: Sendable {
    let refreshReason: TerminalLifecycleExecutorGeometryRefreshReason?
}

struct TerminalLifecycleExecutorTransientLossApplicationPlan: Sendable {
    let transientRecoveryReason: TerminalLifecycleExecutorTransientRecoveryReason?
    let transientRetryDirective: TerminalLifecycleExecutorTransientRetryDirective
    let hiddenStateAction: TerminalLifecycleExecutorHiddenStateAction
    let followUpAction: TerminalLifecycleExecutorTransientFollowUpAction
}

enum TerminalLifecycleExecutorHiddenStateAction: String, Sendable {
    case preserveVisible
    case hideHostedView
    case unmountHostedView
}

enum TerminalLifecycleExecutorTransientFollowUpAction: Sendable, Equatable {
    case none
    case retry(TerminalLifecycleExecutorTransientRecoveryReason)
    case deferredFullSynchronize
}

enum TerminalLifecycleExecutorTransientRetryDirective: Sendable, Equatable {
    case schedule(TerminalLifecycleExecutorTransientRecoveryReason)
    case reset
}

struct TerminalLifecycleExecutorTransientLossPlan: Sendable {
    let transientRecoveryReason: TerminalLifecycleExecutorTransientRecoveryReason?
    let shouldRequestTransientRecovery: Bool
    let followUpAction: TerminalLifecycleExecutorTransientFollowUpAction
    private let targetVisible: Bool
    private let hostedHidden: Bool

    init(
        transientRecoveryReason: TerminalLifecycleExecutorTransientRecoveryReason?,
        shouldRequestTransientRecovery: Bool,
        followUpAction: TerminalLifecycleExecutorTransientFollowUpAction,
        targetVisible: Bool,
        hostedHidden: Bool
    ) {
        self.transientRecoveryReason = transientRecoveryReason
        self.shouldRequestTransientRecovery = shouldRequestTransientRecovery
        self.followUpAction = followUpAction
        self.targetVisible = targetVisible
        self.hostedHidden = hostedHidden
    }

    func hiddenStateAction(
        didScheduleTransientRecovery: Bool
    ) -> TerminalLifecycleExecutorHiddenStateAction {
        TerminalLifecycleExecutor.hiddenStateAction(
            targetVisible: targetVisible,
            hostedHidden: hostedHidden,
            didScheduleTransientRecovery: shouldRequestTransientRecovery && didScheduleTransientRecovery
        )
    }

    var transientRetryDirective: TerminalLifecycleExecutorTransientRetryDirective {
        guard shouldRequestTransientRecovery,
              let transientRecoveryReason else {
            return .reset
        }
        return .schedule(transientRecoveryReason)
    }

    func applicationPlan(
        didScheduleTransientRecovery: Bool
    ) -> TerminalLifecycleExecutorTransientLossApplicationPlan {
        TerminalLifecycleExecutorTransientLossApplicationPlan(
            transientRecoveryReason: transientRecoveryReason,
            transientRetryDirective: transientRetryDirective,
            hiddenStateAction: hiddenStateAction(
                didScheduleTransientRecovery: didScheduleTransientRecovery
            ),
            followUpAction: followUpAction
        )
    }
}

struct TerminalLifecycleExecutorFrameVisibilityContext: Sendable {
    let transientRecoveryEnabled: Bool
    let targetVisible: Bool
    let hostedHidden: Bool
    let anchorHidden: Bool
    let hasFiniteFrame: Bool
    let outsideHostBounds: Bool
    let tinyFrame: Bool
    let revealReadyForDisplay: Bool
}

struct TerminalLifecycleExecutorFrameLossPlan: Sendable {
    let shouldHide: Bool
    let shouldDeferReveal: Bool
    let transientRecoveryReason: TerminalLifecycleExecutorTransientRecoveryReason?
    let shouldRequestTransientRecovery: Bool
    private let targetVisible: Bool
    private let hostedHidden: Bool
    private let revealReadyForDisplay: Bool

    init(
        shouldHide: Bool,
        shouldDeferReveal: Bool,
        transientRecoveryReason: TerminalLifecycleExecutorTransientRecoveryReason?,
        shouldRequestTransientRecovery: Bool,
        targetVisible: Bool,
        hostedHidden: Bool,
        revealReadyForDisplay: Bool
    ) {
        self.shouldHide = shouldHide
        self.shouldDeferReveal = shouldDeferReveal
        self.transientRecoveryReason = transientRecoveryReason
        self.shouldRequestTransientRecovery = shouldRequestTransientRecovery
        self.targetVisible = targetVisible
        self.hostedHidden = hostedHidden
        self.revealReadyForDisplay = revealReadyForDisplay
    }

    func hiddenStateAction(
        didScheduleTransientRecovery: Bool
    ) -> TerminalLifecycleExecutorHiddenStateAction {
        TerminalLifecycleExecutor.hiddenStateAction(
            targetVisible: targetVisible,
            hostedHidden: hostedHidden,
            didScheduleTransientRecovery: shouldRequestTransientRecovery && didScheduleTransientRecovery
        )
    }

    var transientRetryDirective: TerminalLifecycleExecutorTransientRetryDirective {
        guard shouldRequestTransientRecovery,
              let transientRecoveryReason else {
            return .reset
        }
        return .schedule(transientRecoveryReason)
    }

    func visibilityTransition(
        didScheduleTransientRecovery: Bool
    ) -> TerminalLifecycleExecutorVisibilityTransitionDecision {
        TerminalLifecycleExecutor.visibilityTransitionDecision(
            targetVisible: targetVisible,
            hostedHidden: hostedHidden,
            shouldHide: shouldHide,
            revealReadyForDisplay: revealReadyForDisplay,
            didScheduleTransientRecovery: shouldRequestTransientRecovery && didScheduleTransientRecovery
        )
    }

    func applicationPlan(
        didScheduleTransientRecovery: Bool
    ) -> TerminalLifecycleExecutorFrameApplicationPlan {
        let hiddenStateAction = hiddenStateAction(
            didScheduleTransientRecovery: didScheduleTransientRecovery
        )
        let visibilityTransition = visibilityTransition(
            didScheduleTransientRecovery: didScheduleTransientRecovery
        )
        return TerminalLifecycleExecutorFrameApplicationPlan(
            shouldHide: shouldHide,
            shouldDeferReveal: shouldDeferReveal,
            transientRecoveryReason: transientRecoveryReason,
            transientRetryDirective: transientRetryDirective,
            hiddenStateAction: hiddenStateAction,
            visibilityTransition: visibilityTransition
        )
    }
}

enum TerminalLifecycleExecutorTransientRecoveryReason: String, Sendable {
    case missingAnchorOrWindow
    case anchorWindowMismatch
    case hostBoundsNotReady
    case anchorHidden
    case nonFiniteFrame
    case outsideHostBounds
    case tinyFrame
    case deferReveal
}

struct TerminalLifecycleExecutorTransientRecoveryContext: Sendable {
    let transientRecoveryEnabled: Bool
    let targetVisible: Bool
    let missingAnchorOrWindow: Bool
    let anchorWindowMismatch: Bool
    let hostBoundsNotReady: Bool
    let anchorHidden: Bool
    let hasFiniteFrame: Bool
    let outsideHostBounds: Bool
    let tinyFrame: Bool
    let shouldDeferReveal: Bool
}

enum TerminalLifecycleExecutor {
    static func hostedStateApplicationPlan(
        target: TerminalLifecycleExecutorRuntimeTarget,
        hostedViewHasSuperview: Bool,
        isBoundToCurrentHost: Bool
    ) -> TerminalLifecycleExecutorHostedStateApplicationPlan {
        let shouldApplyImmediately: Bool
        // If the hosted view is already bound to the current live anchor, the
        // executor-owned target is authoritative for immediate visible/active updates.
        if isBoundToCurrentHost {
            shouldApplyImmediately = true
        } else if !hostedViewHasSuperview {
            // If the hosted view is detached, there is no competing bound host to preserve.
            shouldApplyImmediately = true
        } else {
            switch target.targetResidency {
            case .visibleInActiveWindow, .parkedOffscreen, .detachedRetained, .destroyed:
                // Otherwise keep the current bound host authoritative until reconciliation finishes.
                shouldApplyImmediately = false
            }
        }

        return TerminalLifecycleExecutorHostedStateApplicationPlan(
            shouldApplyImmediately: shouldApplyImmediately,
            visibleInUI: target.targetVisible,
            active: target.targetActive
        )
    }

    static func isCurrentGenerationBoundVisibleReadyForWorkspaceHandoff(
        currentRecord: PanelLifecycleRecordSnapshot,
        desiredRecord: PanelLifecycleDesiredRecordSnapshot,
        binding: TerminalLifecycleExecutorBindingSnapshot?
    ) -> Bool {
        guard currentRecord.panelType == .terminal, desiredRecord.panelType == .terminal else {
            return false
        }
        guard desiredRecord.targetState == .boundVisible,
              desiredRecord.targetResidency == .visibleInActiveWindow,
              desiredRecord.targetVisible,
              desiredRecord.targetActive else {
            return false
        }

        let runtimeTarget = runtimeTarget(
            desiredRecord: desiredRecord,
            fallbackVisible: currentRecord.desiredVisible,
            fallbackActive: currentRecord.desiredActive,
            expectedAnchorId: desiredRecord.targetAnchorId,
            binding: binding
        )

        return currentRecord.generation == desiredRecord.generation &&
            currentRecord.state == .boundVisible &&
            currentRecord.residency == .visibleInActiveWindow &&
            currentRecord.activeWindowMembership &&
            runtimeTarget.decision.action == .noop &&
            runtimeTarget.decision.bindingSatisfied
    }

    static func recoveryDecision(
        target: TerminalLifecycleExecutorRuntimeTarget,
        hostedView: TerminalLifecycleExecutorHostedViewSnapshot
    ) -> TerminalLifecycleExecutorRecoveryDecision {
        guard target.targetVisible else {
            return TerminalLifecycleExecutorRecoveryDecision(
                shouldRequestViewReattach: false,
                shouldRequestBackgroundSurfaceStart: false
            )
        }

        let shouldRequestViewReattach =
            target.shouldMountLiveAnchor &&
            (
                !hostedView.hasSuperview ||
                    !hostedView.inWindow ||
                    hostedView.hidden ||
                    !hostedView.hasUsableGeometry ||
                    target.decision.action == .bindVisible ||
                    target.decision.action == .waitForAnchor
            )

        return TerminalLifecycleExecutorRecoveryDecision(
            shouldRequestViewReattach: shouldRequestViewReattach,
            shouldRequestBackgroundSurfaceStart: !hostedView.hasSurface
        )
    }

    static func visibilityTransitionDecision(
        targetVisible: Bool,
        hostedHidden: Bool,
        shouldHide: Bool,
        revealReadyForDisplay: Bool,
        didScheduleTransientRecovery: Bool
    ) -> TerminalLifecycleExecutorVisibilityTransitionDecision {
        let shouldPreserveVisibleOnTransientLoss =
            didScheduleTransientRecovery &&
            shouldHide &&
            targetVisible &&
            !hostedHidden

        let shouldDeferReveal =
            targetVisible &&
            !shouldHide &&
            hostedHidden &&
            !revealReadyForDisplay

        return TerminalLifecycleExecutorVisibilityTransitionDecision(
            shouldPreserveVisibleOnTransientLoss: shouldPreserveVisibleOnTransientLoss,
            shouldDeferReveal: shouldDeferReveal,
            shouldRevealHostedView: shouldDeferReveal == false &&
                targetVisible &&
                !shouldHide &&
                hostedHidden &&
                revealReadyForDisplay
        )
    }

    static func hiddenStateAction(
        targetVisible: Bool,
        hostedHidden: Bool,
        didScheduleTransientRecovery: Bool
    ) -> TerminalLifecycleExecutorHiddenStateAction {
        let visibilityTransition = visibilityTransitionDecision(
            targetVisible: targetVisible,
            hostedHidden: hostedHidden,
            shouldHide: true,
            revealReadyForDisplay: false,
            didScheduleTransientRecovery: didScheduleTransientRecovery
        )
        if visibilityTransition.shouldPreserveVisibleOnTransientLoss {
            return .preserveVisible
        }
        return targetVisible ? .hideHostedView : .unmountHostedView
    }

    static func transientRecoveryReason(
        context: TerminalLifecycleExecutorTransientRecoveryContext
    ) -> TerminalLifecycleExecutorTransientRecoveryReason? {
        guard context.transientRecoveryEnabled, context.targetVisible else { return nil }
        if context.missingAnchorOrWindow { return .missingAnchorOrWindow }
        if context.anchorWindowMismatch { return .anchorWindowMismatch }
        if context.hostBoundsNotReady { return .hostBoundsNotReady }
        if context.anchorHidden { return .anchorHidden }
        if !context.hasFiniteFrame { return .nonFiniteFrame }
        if context.outsideHostBounds { return .outsideHostBounds }
        if context.tinyFrame { return .tinyFrame }
        if context.shouldDeferReveal { return .deferReveal }
        return nil
    }

    static func transientLossPlan(
        context: TerminalLifecycleExecutorTransientRecoveryContext,
        hostedHidden: Bool
    ) -> TerminalLifecycleExecutorTransientLossPlan {
        let transientRecoveryReason = transientRecoveryReason(context: context)
        return TerminalLifecycleExecutorTransientLossPlan(
            transientRecoveryReason: transientRecoveryReason,
            shouldRequestTransientRecovery: transientRecoveryReason != nil,
            followUpAction: transientFollowUpAction(
                context: context,
                transientRecoveryReason: transientRecoveryReason
            ),
            targetVisible: context.targetVisible,
            hostedHidden: hostedHidden
        )
    }

    static func transientFollowUpAction(
        context: TerminalLifecycleExecutorTransientRecoveryContext,
        transientRecoveryReason: TerminalLifecycleExecutorTransientRecoveryReason?
    ) -> TerminalLifecycleExecutorTransientFollowUpAction {
        guard context.targetVisible else { return .none }
        if context.anchorWindowMismatch {
            guard let transientRecoveryReason else { return .none }
            return .retry(transientRecoveryReason)
        }
        if context.hostBoundsNotReady {
            guard let transientRecoveryReason else { return .deferredFullSynchronize }
            return .retry(transientRecoveryReason)
        }
        return .none
    }

    static func frameLossPlan(
        context: TerminalLifecycleExecutorFrameVisibilityContext
    ) -> TerminalLifecycleExecutorFrameLossPlan {
        let shouldHide =
            !context.targetVisible ||
            context.anchorHidden ||
            context.tinyFrame ||
            !context.hasFiniteFrame ||
            context.outsideHostBounds

        let initialVisibilityTransition = visibilityTransitionDecision(
            targetVisible: context.targetVisible,
            hostedHidden: context.hostedHidden,
            shouldHide: shouldHide,
            revealReadyForDisplay: context.revealReadyForDisplay,
            didScheduleTransientRecovery: false
        )

        let transientRecoveryReason = transientRecoveryReason(
            context: TerminalLifecycleExecutorTransientRecoveryContext(
                transientRecoveryEnabled: context.transientRecoveryEnabled,
                targetVisible: context.targetVisible,
                missingAnchorOrWindow: false,
                anchorWindowMismatch: false,
                hostBoundsNotReady: false,
                anchorHidden: context.anchorHidden,
                hasFiniteFrame: context.hasFiniteFrame,
                outsideHostBounds: context.outsideHostBounds,
                tinyFrame: context.tinyFrame,
                shouldDeferReveal: initialVisibilityTransition.shouldDeferReveal
            )
        )

        return TerminalLifecycleExecutorFrameLossPlan(
            shouldHide: shouldHide,
            shouldDeferReveal: initialVisibilityTransition.shouldDeferReveal,
            transientRecoveryReason: transientRecoveryReason,
            shouldRequestTransientRecovery: transientRecoveryReason != nil,
            targetVisible: context.targetVisible,
            hostedHidden: context.hostedHidden,
            revealReadyForDisplay: context.revealReadyForDisplay
        )
    }

    static func frameGeometryApplicationPlan(
        hasFiniteFrame: Bool,
        oldFrame: NSRect,
        targetFrame: NSRect,
        currentBounds: NSRect
    ) -> TerminalLifecycleExecutorFrameGeometryApplicationPlan {
        let shouldApplyFrame =
            hasFiniteFrame &&
            !rectApproximatelyEqual(oldFrame, targetFrame)
        let expectedBounds = NSRect(origin: .zero, size: targetFrame.size)
        let shouldApplyBounds =
            hasFiniteFrame &&
            !rectApproximatelyEqual(currentBounds, expectedBounds)
        return TerminalLifecycleExecutorFrameGeometryApplicationPlan(
            shouldApplyFrame: shouldApplyFrame,
            shouldApplyBounds: shouldApplyBounds,
            shouldReconcileGeometry: shouldApplyFrame,
            refreshReason: shouldApplyFrame ? .portalFrameChange : nil
        )
    }

    static func revealApplicationPlan(
        visibilityTransition: TerminalLifecycleExecutorVisibilityTransitionDecision
    ) -> TerminalLifecycleExecutorRevealApplicationPlan {
        TerminalLifecycleExecutorRevealApplicationPlan(
            shouldRevealHostedView: visibilityTransition.shouldRevealHostedView,
            shouldReconcileGeometry: visibilityTransition.shouldRevealHostedView,
            refreshReason: visibilityTransition.shouldRevealHostedView ? .portalReveal : nil
        )
    }

    static func bindSeedPlan(
        seededFrame: NSRect?
    ) -> TerminalLifecycleExecutorBindSeedPlan {
        if let seededFrame,
           seededFrame.width > 0,
           seededFrame.height > 0 {
            return TerminalLifecycleExecutorBindSeedPlan(
                frame: seededFrame,
                bounds: NSRect(origin: .zero, size: seededFrame.size),
                shouldHideHostedView: false,
                shouldReconcileGeometry: true
            )
        }

        return TerminalLifecycleExecutorBindSeedPlan(
            frame: .zero,
            bounds: .zero,
            shouldHideHostedView: true,
            shouldReconcileGeometry: true
        )
    }

    static func externalGeometryApplicationPlan(
        didReconcileGeometry: Bool
    ) -> TerminalLifecycleExecutorExternalGeometryApplicationPlan {
        TerminalLifecycleExecutorExternalGeometryApplicationPlan(
            refreshReason: didReconcileGeometry ? .portalExternalGeometrySync : nil
        )
    }

    private static func rectApproximatelyEqual(
        _ lhs: NSRect,
        _ rhs: NSRect,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
            abs(lhs.size.width - rhs.size.width) <= tolerance &&
            abs(lhs.size.height - rhs.size.height) <= tolerance
    }

    static func makePlan(
        currentRecords: [PanelLifecycleRecordSnapshot],
        desiredRecords: [PanelLifecycleDesiredRecordSnapshot],
        currentBindings: [TerminalLifecycleExecutorBindingSnapshot] = []
    ) -> TerminalLifecycleExecutorPlanSnapshot {
        let currentByPanelId = Dictionary(
            uniqueKeysWithValues: currentRecords
                .filter { $0.panelType == .terminal }
                .map { ($0.panelId, $0) }
        )
        let bindingByPanelId = Dictionary(uniqueKeysWithValues: currentBindings.map { ($0.panelId, $0) })
        let records = desiredRecords.compactMap { desired -> TerminalLifecycleExecutorRecordSnapshot? in
            guard desired.panelType == .terminal else {
                return nil
            }
            let current = currentByPanelId[desired.panelId] ?? syntheticCurrentRecord(for: desired)
            let binding = bindingByPanelId[desired.panelId]
            let bindingSatisfied = isBindingSatisfied(binding: binding, desired: desired)
            let action = plannedAction(
                current: current,
                desired: desired,
                binding: binding,
                bindingSatisfied: bindingSatisfied
            )
            return TerminalLifecycleExecutorRecordSnapshot(
                panelId: current.panelId,
                workspaceId: current.workspaceId,
                generation: desired.generation,
                action: action,
                currentState: current.state,
                targetState: desired.targetState,
                currentResidency: current.residency,
                targetResidency: desired.targetResidency,
                currentVisible: current.activeWindowMembership,
                targetVisible: desired.targetVisible,
                currentActive: current.desiredActive,
                targetActive: desired.targetActive,
                requiresCurrentGenerationAnchor: desired.requiresCurrentGenerationAnchor,
                anchorReadyForVisibility: desired.anchorReadyForVisibility,
                targetWindowNumber: desired.targetWindowNumber,
                targetAnchorId: desired.targetAnchorId,
                bindingPresent: binding != nil,
                bindingSatisfied: bindingSatisfied,
                bindingAnchorId: binding?.anchorId,
                bindingWindowNumber: binding?.windowNumber,
                bindingVisibleInUI: binding?.visibleInUI,
                bindingHostedHidden: binding?.hostedHidden,
                bindingAttachedToPortalHost: binding?.attachedToPortalHost,
                bindingGeneration: binding?.guardGeneration,
                bindingState: binding?.guardState
            )
        }

        return TerminalLifecycleExecutorPlanSnapshot(
            counts: counts(for: records),
            bindingCounts: bindingCounts(for: currentBindings),
            bindings: currentBindings.sorted { lhs, rhs in
                lhs.panelId.uuidString < rhs.panelId.uuidString
            },
            records: records
        )
    }

    private static func syntheticCurrentRecord(
        for desired: PanelLifecycleDesiredRecordSnapshot
    ) -> PanelLifecycleRecordSnapshot {
        PanelLifecycleRecordSnapshot(
            panelId: desired.panelId,
            workspaceId: desired.workspaceId,
            paneId: nil,
            tabId: nil,
            panelType: .terminal,
            generation: desired.generation,
            state: .closed,
            residency: .destroyed,
            mountedWorkspace: false,
            selectedWorkspace: false,
            retiringWorkspace: false,
            selectedInPane: false,
            desiredVisible: false,
            desiredActive: false,
            activeWindowMembership: false,
            responderEligible: false,
            accessibilityParticipation: false,
            backendProfile: PanelLifecycleShadowMapper.backendProfile(for: .terminal),
            anchor: nil
        )
    }

    private static func plannedAction(
        current: PanelLifecycleRecordSnapshot,
        desired: PanelLifecycleDesiredRecordSnapshot,
        binding: TerminalLifecycleExecutorBindingSnapshot?,
        bindingSatisfied: Bool
    ) -> TerminalLifecycleExecutorAction {
        if desired.targetVisible {
            if !desired.anchorReadyForVisibility {
                return .waitForAnchor
            }
            return bindingSatisfied ? .noop : .bindVisible
        }

        switch desired.targetResidency {
        case .detachedRetained:
            return isHiddenTargetSatisfied(current: current, desired: desired, binding: binding)
                ? .noop
                : .moveToDetachedRetained
        case .parkedOffscreen:
            return isHiddenTargetSatisfied(current: current, desired: desired, binding: binding)
                ? .noop
                : .moveToParkedOffscreen
        case .destroyed:
            return isHiddenTargetSatisfied(current: current, desired: desired, binding: binding)
                ? .noop
                : .destroy
        case .visibleInActiveWindow:
            return desired.anchorReadyForVisibility && bindingSatisfied ? .noop : .bindVisible
        }
    }

    private static func isBindingSatisfied(
        binding: TerminalLifecycleExecutorBindingSnapshot?,
        desired: PanelLifecycleDesiredRecordSnapshot
    ) -> Bool {
        guard let binding else { return false }
        if desired.targetVisible {
            return binding.windowNumber == desired.targetWindowNumber &&
                binding.anchorId == desired.targetAnchorId &&
                binding.visibleInUI &&
                !binding.hostedHidden &&
                binding.attachedToPortalHost &&
                (!desired.requiresCurrentGenerationAnchor || binding.guardGeneration == desired.generation)
        }

        switch desired.targetResidency {
        case .parkedOffscreen:
            return !binding.visibleInUI && binding.hostedHidden && binding.attachedToPortalHost
        case .detachedRetained, .destroyed:
            return false
        case .visibleInActiveWindow:
            return binding.windowNumber == desired.targetWindowNumber &&
                binding.visibleInUI &&
                !binding.hostedHidden &&
                binding.attachedToPortalHost
        }
    }

    private static func isHiddenTargetSatisfied(
        current: PanelLifecycleRecordSnapshot,
        desired: PanelLifecycleDesiredRecordSnapshot,
        binding: TerminalLifecycleExecutorBindingSnapshot?
    ) -> Bool {
        switch desired.targetResidency {
        case .detachedRetained:
            return current.residency == .detachedRetained && binding == nil
        case .destroyed:
            return current.residency == .destroyed && binding == nil
        case .parkedOffscreen:
            guard current.residency == .parkedOffscreen else { return false }
            guard let binding else { return true }
            return !binding.visibleInUI && binding.hostedHidden
        case .visibleInActiveWindow:
            return false
        }
    }

    static func runtimeDecision(
        targetResidency: PanelResidency,
        targetVisible: Bool,
        targetWindowNumber: Int?,
        targetAnchorId: UUID?,
        requiresCurrentGenerationAnchor: Bool,
        anchorReadyForVisibility: Bool,
        expectedGeneration: UInt64?,
        binding: TerminalLifecycleExecutorBindingSnapshot?,
        currentGeometryRevision: UInt64? = nil,
        lastSynchronizedGeometryRevision: UInt64? = nil
    ) -> TerminalLifecycleExecutorRuntimeDecision {
        let bindingSatisfied: Bool = {
            guard let binding else { return false }
            if targetVisible {
                return binding.windowNumber == targetWindowNumber &&
                    binding.anchorId == targetAnchorId &&
                    binding.visibleInUI &&
                    !binding.hostedHidden &&
                    binding.attachedToPortalHost &&
                    (!requiresCurrentGenerationAnchor || binding.guardGeneration == expectedGeneration)
            }

            switch targetResidency {
            case .parkedOffscreen:
                return !binding.visibleInUI && binding.hostedHidden && binding.attachedToPortalHost
            case .detachedRetained, .destroyed:
                return false
            case .visibleInActiveWindow:
                return binding.windowNumber == targetWindowNumber &&
                    binding.visibleInUI &&
                    !binding.hostedHidden &&
                    binding.attachedToPortalHost
            }
        }()

        let shouldSynchronizeVisibleGeometry =
            targetVisible &&
            anchorReadyForVisibility &&
            bindingSatisfied &&
            currentGeometryRevision != lastSynchronizedGeometryRevision

        let action: TerminalLifecycleExecutorAction
        if targetVisible {
            if !anchorReadyForVisibility {
                action = .waitForAnchor
            } else {
                action = bindingSatisfied ? .noop : .bindVisible
            }
        } else {
            switch targetResidency {
            case .detachedRetained:
                action = binding == nil ? .noop : .moveToDetachedRetained
            case .parkedOffscreen:
                action = bindingSatisfied ? .noop : .moveToParkedOffscreen
            case .destroyed:
                action = binding == nil ? .noop : .destroy
            case .visibleInActiveWindow:
                action = anchorReadyForVisibility && bindingSatisfied ? .noop : .bindVisible
            }
        }

        return TerminalLifecycleExecutorRuntimeDecision(
            action: action,
            bindingSatisfied: bindingSatisfied,
            shouldSynchronizeVisibleGeometry: shouldSynchronizeVisibleGeometry
        )
    }

    static func runtimeTarget(
        desiredRecord: PanelLifecycleDesiredRecordSnapshot?,
        fallbackVisible: Bool,
        fallbackActive: Bool,
        expectedAnchorId: UUID?,
        binding: TerminalLifecycleExecutorBindingSnapshot?,
        currentGeometryRevision: UInt64? = nil,
        lastSynchronizedGeometryRevision: UInt64? = nil
    ) -> TerminalLifecycleExecutorRuntimeTarget {
        let targetVisible = desiredRecord?.targetVisible ?? fallbackVisible
        let targetActive = desiredRecord?.targetActive ?? fallbackActive
        let targetResidency = desiredRecord?.targetResidency
            ?? (targetVisible ? .visibleInActiveWindow : .detachedRetained)
        let targetWindowNumber = desiredRecord?.targetWindowNumber
        let targetAnchorId = desiredRecord?.targetAnchorId ?? (targetVisible ? expectedAnchorId : nil)
        let requiresCurrentGenerationAnchor = desiredRecord?.requiresCurrentGenerationAnchor ?? false
        let anchorReadyForVisibility = desiredRecord?.anchorReadyForVisibility ?? targetVisible
        let expectedGeneration = desiredRecord?.generation
        let decision = runtimeDecision(
            targetResidency: targetResidency,
            targetVisible: targetVisible,
            targetWindowNumber: targetWindowNumber,
            targetAnchorId: targetAnchorId,
            requiresCurrentGenerationAnchor: requiresCurrentGenerationAnchor,
            anchorReadyForVisibility: anchorReadyForVisibility,
            expectedGeneration: expectedGeneration,
            binding: binding,
            currentGeometryRevision: currentGeometryRevision,
            lastSynchronizedGeometryRevision: lastSynchronizedGeometryRevision
        )

        return TerminalLifecycleExecutorRuntimeTarget(
            targetResidency: targetResidency,
            targetVisible: targetVisible,
            targetActive: targetActive,
            targetWindowNumber: targetWindowNumber,
            targetAnchorId: targetAnchorId,
            requiresCurrentGenerationAnchor: requiresCurrentGenerationAnchor,
            anchorReadyForVisibility: anchorReadyForVisibility,
            decision: decision
        )
    }

    static func runtimeApplicationPlan(
        target: TerminalLifecycleExecutorRuntimeTarget
    ) -> TerminalLifecycleExecutorRuntimeApplicationPlan {
        let decision = target.decision
        switch decision.action {
        case .noop:
            return TerminalLifecycleExecutorRuntimeApplicationPlan(
                decision: decision,
                shouldUpdateEntryVisibility: true,
                entryVisibleInUI: target.targetVisible,
                shouldSynchronizeForAnchor: decision.shouldSynchronizeVisibleGeometry,
                shouldBindVisible: false,
                shouldDetachHostedView: false,
                shouldUnmountHostedView: false
            )
        case .bindVisible:
            return TerminalLifecycleExecutorRuntimeApplicationPlan(
                decision: decision,
                shouldUpdateEntryVisibility: false,
                entryVisibleInUI: target.targetVisible,
                shouldSynchronizeForAnchor: false,
                shouldBindVisible: true,
                shouldDetachHostedView: false,
                shouldUnmountHostedView: false
            )
        case .waitForAnchor:
            return TerminalLifecycleExecutorRuntimeApplicationPlan(
                decision: decision,
                shouldUpdateEntryVisibility: true,
                entryVisibleInUI: target.targetVisible,
                shouldSynchronizeForAnchor: false,
                shouldBindVisible: false,
                shouldDetachHostedView: false,
                shouldUnmountHostedView: false
            )
        case .moveToDetachedRetained, .destroy:
            return TerminalLifecycleExecutorRuntimeApplicationPlan(
                decision: decision,
                shouldUpdateEntryVisibility: false,
                entryVisibleInUI: target.targetVisible,
                shouldSynchronizeForAnchor: false,
                shouldBindVisible: false,
                shouldDetachHostedView: true,
                shouldUnmountHostedView: false
            )
        case .moveToParkedOffscreen:
            return TerminalLifecycleExecutorRuntimeApplicationPlan(
                decision: decision,
                shouldUpdateEntryVisibility: true,
                entryVisibleInUI: target.targetVisible,
                shouldSynchronizeForAnchor: false,
                shouldBindVisible: false,
                shouldDetachHostedView: false,
                shouldUnmountHostedView: true
            )
        }
    }

    private static func counts(
        for records: [TerminalLifecycleExecutorRecordSnapshot]
    ) -> TerminalLifecycleExecutorPlanCounts {
        TerminalLifecycleExecutorPlanCounts(
            panelCount: records.count,
            noopCount: records.filter { $0.action == .noop }.count,
            waitForAnchorCount: records.filter { $0.action == .waitForAnchor }.count,
            bindVisibleCount: records.filter { $0.action == .bindVisible }.count,
            moveToDetachedRetainedCount: records.filter { $0.action == .moveToDetachedRetained }.count,
            moveToParkedOffscreenCount: records.filter { $0.action == .moveToParkedOffscreen }.count,
            destroyCount: records.filter { $0.action == .destroy }.count
        )
    }

    private static func bindingCounts(
        for bindings: [TerminalLifecycleExecutorBindingSnapshot]
    ) -> TerminalLifecycleExecutorBindingCounts {
        TerminalLifecycleExecutorBindingCounts(
            panelCount: bindings.count,
            visibleEntryCount: bindings.filter(\.visibleInUI).count,
            hiddenEntryCount: bindings.filter(\.hostedHidden).count,
            attachedEntryCount: bindings.filter(\.attachedToPortalHost).count,
            currentGenerationCount: bindings.filter { $0.guardGeneration != nil }.count
        )
    }
}
