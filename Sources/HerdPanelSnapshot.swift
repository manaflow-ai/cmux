import Foundation

/// Immutable cross-workspace projection consumed by the Herd panel.
struct HerdPanelSnapshot: Equatable, Sendable {
    struct LaneID: Hashable, Sendable {
        let workspaceID: UUID
        let panelID: UUID
        let agentKey: String?
    }

    enum Lifecycle: String, CaseIterable, Sendable {
        case needsInput
        case working
        case idle
        case unknown
        case terminal

        var sortPriority: Int {
            switch self {
            case .needsInput: 0
            case .working: 1
            case .idle: 2
            case .unknown: 3
            case .terminal: 4
            }
        }
    }

    struct Lane: Identifiable, Equatable, Sendable {
        let id: LaneID
        let workspaceID: UUID
        let panelID: UUID
        let paneID: UUID
        let workspaceTitle: String
        let title: String
        let directory: String?
        let agentKey: String?
        let lifecycle: Lifecycle
        let isFocused: Bool

        var isAgent: Bool { agentKey != nil }
    }

    let lanes: [Lane]

    static let empty = HerdPanelSnapshot(lanes: [])

    var agentCount: Int { lanes.count(where: \.isAgent) }
    var workingCount: Int { lanes.count { $0.lifecycle == .working } }
    var needsInputCount: Int { lanes.count { $0.lifecycle == .needsInput } }
    var idleCount: Int { lanes.count { $0.lifecycle == .idle } }

    @MainActor
    static func capture(tabManager: TabManager) -> HerdPanelSnapshot {
        var lanes: [Lane] = []
        let workspaceOrder = Dictionary(
            uniqueKeysWithValues: tabManager.tabs.enumerated().map { ($0.element.id, $0.offset) }
        )
        var panelOrderByWorkspace: [UUID: [UUID: Int]] = [:]

        for workspace in tabManager.tabs {
            let workspaceTitle = workspace.customTitle ?? workspace.title
            let orderedPanelIDs = workspace.sidebarOrderedPanelIds()
            let panelOrder = Dictionary(uniqueKeysWithValues: orderedPanelIDs.enumerated().map { ($0.element, $0.offset) })
            panelOrderByWorkspace[workspace.id] = panelOrder

            for panelID in orderedPanelIDs {
                guard workspace.panels[panelID] is TerminalPanel,
                      let paneID = workspace.paneId(forPanelId: panelID)?.id else {
                    continue
                }

                let title = workspace.panelCustomTitles[panelID]
                    ?? workspace.panelTitles[panelID]
                    ?? String(localized: "taskManager.row.surfaceType.terminal", defaultValue: "Terminal")
                let directory = normalized(workspace.effectivePanelDirectory(panelId: panelID))
                let agentStates = workspace.agentLifecycleStatesByPanelId[panelID] ?? [:]
                let focused = tabManager.selectedTabId == workspace.id && workspace.focusedPanelId == panelID

                if agentStates.isEmpty {
                    lanes.append(
                        Lane(
                            id: LaneID(workspaceID: workspace.id, panelID: panelID, agentKey: nil),
                            workspaceID: workspace.id,
                            panelID: panelID,
                            paneID: paneID,
                            workspaceTitle: workspaceTitle,
                            title: title,
                            directory: directory,
                            agentKey: nil,
                            lifecycle: .terminal,
                            isFocused: focused
                        )
                    )
                    continue
                }

                for (agentKey, lifecycle) in agentStates.sorted(by: { $0.key < $1.key }) {
                    lanes.append(
                        Lane(
                            id: LaneID(workspaceID: workspace.id, panelID: panelID, agentKey: agentKey),
                            workspaceID: workspace.id,
                            panelID: panelID,
                            paneID: paneID,
                            workspaceTitle: workspaceTitle,
                            title: title,
                            directory: directory,
                            agentKey: agentKey,
                            lifecycle: Lifecycle(lifecycle),
                            isFocused: focused
                        )
                    )
                }
            }

        }

        lanes.sort { lhs, rhs in
            if lhs.lifecycle.sortPriority != rhs.lifecycle.sortPriority {
                return lhs.lifecycle.sortPriority < rhs.lifecycle.sortPriority
            }
            let lhsWorkspace = workspaceOrder[lhs.workspaceID] ?? .max
            let rhsWorkspace = workspaceOrder[rhs.workspaceID] ?? .max
            if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }
            let lhsPanel = panelOrderByWorkspace[lhs.workspaceID]?[lhs.panelID] ?? .max
            let rhsPanel = panelOrderByWorkspace[rhs.workspaceID]?[rhs.panelID] ?? .max
            if lhsPanel != rhsPanel { return lhsPanel < rhsPanel }
            return (lhs.agentKey ?? "") < (rhs.agentKey ?? "")
        }

        return HerdPanelSnapshot(lanes: lanes)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension HerdPanelSnapshot.Lifecycle {
    init(_ lifecycle: AgentHibernationLifecycleState) {
        switch lifecycle {
        case .needsInput: self = .needsInput
        case .running: self = .working
        case .idle: self = .idle
        case .unknown: self = .unknown
        }
    }
}
