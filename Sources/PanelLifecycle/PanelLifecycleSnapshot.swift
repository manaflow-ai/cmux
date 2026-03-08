import Foundation

struct PanelLifecycleAnchorSnapshot: Codable, Sendable {
    let anchorId: UUID
    let anchorGeneration: UInt64
    let windowNumber: Int?
    let hasSuperview: Bool
    let attachedToWindow: Bool
    let hidden: Bool
    let geometryRevision: UInt64
    let source: String
}

struct PanelLifecycleRecordSnapshot: Codable, Sendable {
    let panelId: UUID
    let workspaceId: UUID
    let paneId: UUID?
    let tabId: UUID?
    let panelType: PanelType
    let generation: UInt64
    let state: PanelLifecycleState
    let residency: PanelResidency
    let mountedWorkspace: Bool
    let selectedWorkspace: Bool
    let retiringWorkspace: Bool
    let selectedInPane: Bool
    let desiredVisible: Bool
    let desiredActive: Bool
    let activeWindowMembership: Bool
    let responderEligible: Bool
    let accessibilityParticipation: Bool
    let backendProfile: PanelLifecycleBackendProfile
    let anchor: PanelLifecycleAnchorSnapshot?
}

struct PanelLifecycleSnapshotCounts: Codable, Sendable {
    let panelCount: Int
    let anchoredPanelCount: Int
    let nonVisibleAnchoredPanelCount: Int
    let inactiveTabAnchoredPanelCount: Int
    let visibleInActiveWindowCount: Int
    let responderEligibleCount: Int
    let accessibilityParticipationCount: Int
    let mountedWorkspaceCount: Int
}

struct PanelLifecycleDesiredRecordSnapshot: Codable, Sendable {
    let panelId: UUID
    let workspaceId: UUID
    let panelType: PanelType
    let generation: UInt64
    let targetState: PanelLifecycleState
    let targetResidency: PanelResidency
    let targetVisible: Bool
    let targetActive: Bool
    let targetWindowNumber: Int?
    let targetAnchorId: UUID?
    let targetResponderEligible: Bool
    let targetAccessibilityParticipation: Bool
    let requiresCurrentGenerationAnchor: Bool
    let anchorReadyForVisibility: Bool
}

struct PanelLifecycleDesiredSnapshotCounts: Codable, Sendable {
    let panelCount: Int
    let visibleTargetCount: Int
    let activeTargetCount: Int
    let awaitingAnchorCount: Int
    let visibleInActiveWindowCount: Int
    let parkedOffscreenCount: Int
    let detachedRetainedCount: Int
    let destroyedCount: Int
}

struct PanelLifecycleDivergenceCounts: Codable, Sendable {
    let panelCount: Int
    let stateMismatchCount: Int
    let residencyMismatchCount: Int
    let activeWindowMismatchCount: Int
    let responderMismatchCount: Int
    let accessibilityMismatchCount: Int
    let anchorRequiredButMissingCount: Int
}

struct PanelLifecycleDesiredSnapshot: Codable, Sendable {
    let counts: PanelLifecycleDesiredSnapshotCounts
    let divergence: PanelLifecycleDivergenceCounts
    let terminalExecutorPlan: TerminalLifecycleExecutorPlanSnapshot
    let browserExecutorPlan: BrowserLifecycleExecutorPlanSnapshot
    let documentExecutorPlan: DocumentLifecycleExecutorPlanSnapshot
    let records: [PanelLifecycleDesiredRecordSnapshot]
}

struct PanelLifecycleExecutorAuditTotals: Codable, Sendable {
    let entryCount: Int
    let mappedObjectCount: Int
    let hostSubviewCount: Int
    let hostedSubviewCount: Int
    let mappedHostedSubviewCount: Int
    let orphanHostedSubviewCount: Int
    let visibleOrphanHostedSubviewCount: Int
    let staleEntryCount: Int
}

struct PanelLifecycleExecutorAuditWindowSnapshot: Codable, Sendable {
    let windowNumber: Int
    let entryCount: Int
    let mappedObjectCount: Int
    let hostSubviewCount: Int
    let hostedSubviewCount: Int
    let mappedHostedSubviewCount: Int
    let orphanHostedSubviewCount: Int
    let visibleOrphanHostedSubviewCount: Int
    let staleEntryCount: Int
    let integrityOK: Bool
}

struct PanelLifecycleExecutorKindAuditSnapshot: Codable, Sendable {
    let portalCount: Int
    let mappingCount: Int
    let guardedBindBlockedCount: Int?
    let guardedBindBlockedReasons: [String: Int]?
    let totals: PanelLifecycleExecutorAuditTotals
    let portals: [PanelLifecycleExecutorAuditWindowSnapshot]
}

struct PanelLifecycleExecutorAuditSnapshot: Codable, Sendable {
    let terminal: PanelLifecycleExecutorKindAuditSnapshot
    let browser: PanelLifecycleExecutorKindAuditSnapshot
}

struct PanelLifecycleSnapshot: Codable, Sendable {
    let selectedWorkspaceId: UUID?
    let retiringWorkspaceId: UUID?
    let mountedWorkspaceIds: [UUID]
    let handoffGeneration: UInt64
    let activeWindowNumber: Int?
    let counts: PanelLifecycleSnapshotCounts
    let desired: PanelLifecycleDesiredSnapshot
    let audit: PanelLifecycleExecutorAuditSnapshot?
    let records: [PanelLifecycleRecordSnapshot]
}
