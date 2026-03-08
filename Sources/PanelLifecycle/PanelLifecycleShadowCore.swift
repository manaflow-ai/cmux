import Foundation

enum PanelLifecycleShadowMapper {
    private static func steadyStateHiddenResidency(
        for residencyPolicy: PanelResidencyPolicy
    ) -> PanelResidency {
        switch residencyPolicy {
        case .persistent:
            return .detachedRetained
        case .parked:
            return .parkedOffscreen
        case .regenerable:
            return .destroyed
        }
    }

    static func desiredVisible(
        isWorkspaceVisible: Bool,
        selectedInPane: Bool,
        isFocused: Bool
    ) -> Bool {
        WorkspaceContentView.panelVisibleInUI(
            isWorkspaceVisible: isWorkspaceVisible,
            isSelectedInPane: selectedInPane,
            isFocused: isFocused
        )
    }

    static func backendProfile(for panelType: PanelType) -> PanelLifecycleBackendProfile {
        switch panelType {
        case .terminal:
            return PanelLifecycleBackendProfile(
                panelType: panelType,
                residencyPolicy: .persistent,
                interactionModel: .interactive,
                backgroundWorkPolicy: .hiddenLimited,
                focusPolicy: .firstResponder,
                accessibilityPolicy: .activeVisibleTree
            )
        case .browser:
            return PanelLifecycleBackendProfile(
                panelType: panelType,
                residencyPolicy: .parked,
                interactionModel: .interactive,
                backgroundWorkPolicy: .hiddenLimited,
                focusPolicy: .firstResponder,
                accessibilityPolicy: .activeVisibleTree
            )
        case .markdown:
            return PanelLifecycleBackendProfile(
                panelType: panelType,
                residencyPolicy: .regenerable,
                interactionModel: .readOnly,
                backgroundWorkPolicy: .hiddenRebuild,
                focusPolicy: .none,
                accessibilityPolicy: .activeVisibleTree
            )
        }
    }

    static func state(
        mountedWorkspace: Bool,
        retiringWorkspace: Bool,
        desiredVisible: Bool,
        anchorAttachedToWindow: Bool
    ) -> PanelLifecycleState {
        if retiringWorkspace && desiredVisible && mountedWorkspace {
            return .handoff
        }
        if desiredVisible {
            return anchorAttachedToWindow ? .boundVisible : .awaitingAnchor
        }
        if mountedWorkspace {
            return .boundHidden
        }
        return .parked
    }

    static func residency(
        residencyPolicy: PanelResidencyPolicy,
        activeWindowMembership: Bool,
        attachedToWindow: Bool,
        hasSuperview: Bool,
        desiredVisible: Bool
    ) -> PanelResidency {
        if activeWindowMembership {
            return .visibleInActiveWindow
        }
        if attachedToWindow || hasSuperview {
            return .parkedOffscreen
        }
        if residencyPolicy == .regenerable && !desiredVisible {
            return .destroyed
        }
        return .detachedRetained
    }

    static func record(
        input: PanelLifecycleShadowRecordInput,
        activeWindowNumber: Int?,
        handoffGeneration: UInt64
    ) -> PanelLifecycleRecordSnapshot {
        let desiredVisible = desiredVisible(
            isWorkspaceVisible: input.mountedWorkspace && (input.selectedWorkspace || input.retiringWorkspace),
            selectedInPane: input.selectedInPane,
            isFocused: input.isFocused
        )
        let desiredActive = input.selectedWorkspace && input.isFocused
        let backendProfile = backendProfile(for: input.panelType)

        let anchor = input.anchorFact.map {
            PanelLifecycleAnchorSnapshot(
                anchorId: $0.anchorId,
                anchorGeneration: input.anchorGeneration,
                windowNumber: $0.windowNumber,
                hasSuperview: $0.hasSuperview,
                attachedToWindow: $0.attachedToWindow,
                hidden: $0.hidden,
                geometryRevision: $0.geometryRevision,
                source: $0.source
            )
        }

        let activeWindowMembership =
            desiredVisible &&
            (input.anchorFact?.windowNumber == activeWindowNumber) &&
            (input.anchorFact?.attachedToWindow ?? false) &&
            !(input.anchorFact?.hidden ?? false)

        let responderEligible =
            activeWindowMembership &&
            desiredActive &&
            backendProfile.focusPolicy == .firstResponder

        let accessibilityParticipation =
            activeWindowMembership &&
            backendProfile.accessibilityPolicy == .activeVisibleTree

        let state = state(
            mountedWorkspace: input.mountedWorkspace,
            retiringWorkspace: input.retiringWorkspace,
            desiredVisible: desiredVisible,
            anchorAttachedToWindow: input.anchorFact?.attachedToWindow ?? desiredVisible
        )

        let residency = residency(
            residencyPolicy: backendProfile.residencyPolicy,
            activeWindowMembership: activeWindowMembership,
            attachedToWindow: input.anchorFact?.attachedToWindow ?? false,
            hasSuperview: input.anchorFact?.hasSuperview ?? false,
            desiredVisible: desiredVisible
        )

        let generation: UInt64 = (input.selectedWorkspace || input.retiringWorkspace) ? handoffGeneration : 0

        return PanelLifecycleRecordSnapshot(
            panelId: input.panelId,
            workspaceId: input.workspaceId,
            paneId: input.paneId,
            tabId: input.tabId,
            panelType: input.panelType,
            generation: generation,
            state: state,
            residency: residency,
            mountedWorkspace: input.mountedWorkspace,
            selectedWorkspace: input.selectedWorkspace,
            retiringWorkspace: input.retiringWorkspace,
            selectedInPane: input.selectedInPane,
            desiredVisible: desiredVisible,
            desiredActive: desiredActive,
            activeWindowMembership: activeWindowMembership,
            responderEligible: responderEligible,
            accessibilityParticipation: accessibilityParticipation,
            backendProfile: backendProfile,
            anchor: anchor
        )
    }

    static func counts(
        for records: [PanelLifecycleRecordSnapshot],
        mountedWorkspaceCount: Int
    ) -> PanelLifecycleSnapshotCounts {
        PanelLifecycleSnapshotCounts(
            panelCount: records.count,
            anchoredPanelCount: records.filter { $0.anchor != nil }.count,
            nonVisibleAnchoredPanelCount: records.filter { $0.anchor != nil && !$0.desiredVisible }.count,
            inactiveTabAnchoredPanelCount: records.filter {
                $0.anchor != nil &&
                    $0.mountedWorkspace &&
                    !$0.selectedInPane &&
                    !$0.desiredVisible
            }.count,
            visibleInActiveWindowCount: records.filter(\.activeWindowMembership).count,
            responderEligibleCount: records.filter(\.responderEligible).count,
            accessibilityParticipationCount: records.filter(\.accessibilityParticipation).count,
            mountedWorkspaceCount: mountedWorkspaceCount
        )
    }

    static func desiredRecord(
        from record: PanelLifecycleRecordSnapshot,
        activeWindowNumber: Int?
    ) -> PanelLifecycleDesiredRecordSnapshot {
        let requiresCurrentGenerationAnchor = record.desiredVisible
        let anchorReadyForVisibility =
            record.anchor?.attachedToWindow == true &&
            record.anchor?.windowNumber == activeWindowNumber &&
            record.anchor?.hidden == false

        let targetState: PanelLifecycleState
        if record.desiredVisible {
            targetState = anchorReadyForVisibility ? .boundVisible : .awaitingAnchor
        } else if record.mountedWorkspace {
            targetState = .boundHidden
        } else {
            targetState = .parked
        }

        let targetResidency: PanelResidency
        if record.desiredVisible {
            targetResidency = .visibleInActiveWindow
        } else {
            targetResidency = steadyStateHiddenResidency(for: record.backendProfile.residencyPolicy)
        }

        let targetResponderEligible =
            record.desiredVisible &&
            record.desiredActive &&
            record.backendProfile.focusPolicy == .firstResponder
        let targetAccessibilityParticipation =
            record.desiredVisible &&
            record.backendProfile.accessibilityPolicy == .activeVisibleTree

        return PanelLifecycleDesiredRecordSnapshot(
            panelId: record.panelId,
            workspaceId: record.workspaceId,
            panelType: record.panelType,
            generation: record.generation,
            targetState: targetState,
            targetResidency: targetResidency,
            targetVisible: record.desiredVisible,
            targetActive: record.desiredActive,
            targetWindowNumber: record.desiredVisible ? activeWindowNumber : nil,
            targetAnchorId: record.desiredVisible ? record.anchor?.anchorId : nil,
            targetResponderEligible: targetResponderEligible,
            targetAccessibilityParticipation: targetAccessibilityParticipation,
            requiresCurrentGenerationAnchor: requiresCurrentGenerationAnchor,
            anchorReadyForVisibility: anchorReadyForVisibility
        )
    }

    static func desiredCounts(
        for records: [PanelLifecycleDesiredRecordSnapshot]
    ) -> PanelLifecycleDesiredSnapshotCounts {
        PanelLifecycleDesiredSnapshotCounts(
            panelCount: records.count,
            visibleTargetCount: records.filter(\.targetVisible).count,
            activeTargetCount: records.filter(\.targetActive).count,
            awaitingAnchorCount: records.filter { $0.targetState == .awaitingAnchor }.count,
            visibleInActiveWindowCount: records.filter { $0.targetResidency == .visibleInActiveWindow }.count,
            parkedOffscreenCount: records.filter { $0.targetResidency == .parkedOffscreen }.count,
            detachedRetainedCount: records.filter { $0.targetResidency == .detachedRetained }.count,
            destroyedCount: records.filter { $0.targetResidency == .destroyed }.count
        )
    }

    static func divergenceCounts(
        currentRecords: [PanelLifecycleRecordSnapshot],
        desiredRecords: [PanelLifecycleDesiredRecordSnapshot]
    ) -> PanelLifecycleDivergenceCounts {
        let desiredByPanelId = Dictionary(uniqueKeysWithValues: desiredRecords.map { ($0.panelId, $0) })

        var stateMismatchCount = 0
        var residencyMismatchCount = 0
        var activeWindowMismatchCount = 0
        var responderMismatchCount = 0
        var accessibilityMismatchCount = 0
        var anchorRequiredButMissingCount = 0

        for current in currentRecords {
            guard let desired = desiredByPanelId[current.panelId] else { continue }
            if current.state != desired.targetState {
                stateMismatchCount += 1
            }
            if current.residency != desired.targetResidency {
                residencyMismatchCount += 1
            }
            if current.activeWindowMembership != desired.targetVisible {
                activeWindowMismatchCount += 1
            }
            if current.responderEligible != desired.targetResponderEligible {
                responderMismatchCount += 1
            }
            if current.accessibilityParticipation != desired.targetAccessibilityParticipation {
                accessibilityMismatchCount += 1
            }
            if desired.requiresCurrentGenerationAnchor && !desired.anchorReadyForVisibility {
                anchorRequiredButMissingCount += 1
            }
        }

        return PanelLifecycleDivergenceCounts(
            panelCount: currentRecords.count,
            stateMismatchCount: stateMismatchCount,
            residencyMismatchCount: residencyMismatchCount,
            activeWindowMismatchCount: activeWindowMismatchCount,
            responderMismatchCount: responderMismatchCount,
            accessibilityMismatchCount: accessibilityMismatchCount,
            anchorRequiredButMissingCount: anchorRequiredButMissingCount
        )
    }
}
