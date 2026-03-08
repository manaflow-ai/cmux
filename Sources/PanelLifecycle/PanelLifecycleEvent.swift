import Foundation

struct PanelLifecycleAnchorFact: Sendable, Equatable {
    let panelId: UUID
    let workspaceId: UUID
    let panelType: PanelType
    let anchorId: UUID
    let windowNumber: Int?
    let hasSuperview: Bool
    let attachedToWindow: Bool
    let hidden: Bool
    let geometryRevision: UInt64
    let desiredVisible: Bool
    let desiredActive: Bool
    let source: String
}

enum PanelLifecycleShadowEvent: Sendable, Equatable {
    case mountedWorkspaceState(mountedWorkspaceIds: [UUID], retiringWorkspaceId: UUID?, handoffGeneration: UInt64)
    case anchorFact(PanelLifecycleAnchorFact)
    case anchorRemoved(panelId: UUID)

    var debugName: String {
        switch self {
        case .mountedWorkspaceState:
            return "mountedWorkspaceState"
        case .anchorFact:
            return "anchorFact"
        case .anchorRemoved:
            return "anchorRemoved"
        }
    }
}

struct PanelLifecycleShadowState: Sendable, Equatable {
    private(set) var mountedWorkspaceIds: Set<UUID> = []
    private(set) var retiringWorkspaceId: UUID?
    private(set) var handoffGeneration: UInt64 = 0
    private(set) var anchorFactsByPanelId: [UUID: PanelLifecycleAnchorFact] = [:]
    private(set) var anchorGenerationsByPanelId: [UUID: UInt64] = [:]

    mutating func reduce(_ event: PanelLifecycleShadowEvent) {
        switch event {
        case .mountedWorkspaceState(let mountedWorkspaceIds, let retiringWorkspaceId, let handoffGeneration):
            self.mountedWorkspaceIds = Set(mountedWorkspaceIds)
            self.retiringWorkspaceId = retiringWorkspaceId
            self.handoffGeneration = handoffGeneration
        case .anchorFact(let fact):
            let priorAnchorId = anchorFactsByPanelId[fact.panelId]?.anchorId
            let priorGeneration = anchorGenerationsByPanelId[fact.panelId] ?? 0
            anchorGenerationsByPanelId[fact.panelId] =
                priorAnchorId == fact.anchorId ? max(1, priorGeneration) : (priorGeneration + 1)
            anchorFactsByPanelId[fact.panelId] = fact
        case .anchorRemoved(let panelId):
            anchorFactsByPanelId.removeValue(forKey: panelId)
        }
    }

    func anchorFact(panelId: UUID) -> PanelLifecycleAnchorFact? {
        anchorFactsByPanelId[panelId]
    }

    func anchorGeneration(panelId: UUID) -> UInt64 {
        anchorGenerationsByPanelId[panelId] ?? 0
    }
}

struct PanelLifecycleShadowRecordInput: Sendable {
    let panelId: UUID
    let workspaceId: UUID
    let paneId: UUID?
    let tabId: UUID?
    let panelType: PanelType
    let mountedWorkspace: Bool
    let selectedWorkspace: Bool
    let retiringWorkspace: Bool
    let selectedInPane: Bool
    let isFocused: Bool
    let anchorFact: PanelLifecycleAnchorFact?
    let anchorGeneration: UInt64
}
