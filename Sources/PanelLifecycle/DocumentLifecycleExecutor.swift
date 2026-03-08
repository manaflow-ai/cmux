import Foundation

enum DocumentLifecycleExecutorAction: String, Codable, Sendable {
    case noop
    case showInTree
    case destroy
}

struct DocumentLifecycleExecutorRecordSnapshot: Codable, Sendable {
    let panelId: UUID
    let workspaceId: UUID
    let generation: UInt64
    let action: DocumentLifecycleExecutorAction
    let currentState: PanelLifecycleState
    let targetState: PanelLifecycleState
    let currentResidency: PanelResidency
    let targetResidency: PanelResidency
    let currentVisible: Bool
    let targetVisible: Bool
    let currentActive: Bool
    let targetActive: Bool
}

struct DocumentLifecycleExecutorPlanCounts: Codable, Sendable {
    let panelCount: Int
    let noopCount: Int
    let showInTreeCount: Int
    let destroyCount: Int
}

struct DocumentLifecycleExecutorPlanSnapshot: Codable, Sendable {
    let counts: DocumentLifecycleExecutorPlanCounts
    let records: [DocumentLifecycleExecutorRecordSnapshot]
}

enum DocumentLifecycleExecutor {
    static func makePlan(
        currentRecords: [PanelLifecycleRecordSnapshot],
        desiredRecords: [PanelLifecycleDesiredRecordSnapshot]
    ) -> DocumentLifecycleExecutorPlanSnapshot {
        let currentByPanelId = Dictionary(
            uniqueKeysWithValues: currentRecords
                .filter { $0.panelType == .markdown }
                .map { ($0.panelId, $0) }
        )

        let records = desiredRecords.compactMap { desired -> DocumentLifecycleExecutorRecordSnapshot? in
            guard desired.panelType == .markdown else { return nil }
            let current = currentByPanelId[desired.panelId] ?? syntheticCurrentRecord(for: desired)
            return DocumentLifecycleExecutorRecordSnapshot(
                panelId: current.panelId,
                workspaceId: current.workspaceId,
                generation: desired.generation,
                action: plannedAction(current: current, desired: desired),
                currentState: current.state,
                targetState: desired.targetState,
                currentResidency: current.residency,
                targetResidency: desired.targetResidency,
                currentVisible: current.activeWindowMembership,
                targetVisible: desired.targetVisible,
                currentActive: current.desiredActive,
                targetActive: desired.targetActive
            )
        }

        return DocumentLifecycleExecutorPlanSnapshot(
            counts: counts(for: records),
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
            panelType: .markdown,
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
            backendProfile: PanelLifecycleShadowMapper.backendProfile(for: .markdown),
            anchor: nil
        )
    }

    private static func plannedAction(
        current: PanelLifecycleRecordSnapshot,
        desired: PanelLifecycleDesiredRecordSnapshot
    ) -> DocumentLifecycleExecutorAction {
        if desired.targetVisible {
            return isVisibleTargetSatisfied(current: current, desired: desired) ? .noop : .showInTree
        }
        if desired.targetResidency == .destroyed {
            return current.residency == .destroyed ? .noop : .destroy
        }
        return .noop
    }

    private static func isVisibleTargetSatisfied(
        current: PanelLifecycleRecordSnapshot,
        desired: PanelLifecycleDesiredRecordSnapshot
    ) -> Bool {
        current.state == desired.targetState &&
            current.residency == desired.targetResidency &&
            current.activeWindowMembership == desired.targetVisible &&
            current.desiredActive == desired.targetActive
    }

    private static func counts(
        for records: [DocumentLifecycleExecutorRecordSnapshot]
    ) -> DocumentLifecycleExecutorPlanCounts {
        DocumentLifecycleExecutorPlanCounts(
            panelCount: records.count,
            noopCount: records.filter { $0.action == .noop }.count,
            showInTreeCount: records.filter { $0.action == .showInTree }.count,
            destroyCount: records.filter { $0.action == .destroy }.count
        )
    }
}
