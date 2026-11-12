import Foundation
@testable import CmuxWorkspaces

enum WorkspacesModelObservationMember: String, CaseIterable, Sendable {
    case tabs
    case workspaceGroups
    case selectedTabId

    var hookEvents: [String] {
        switch self {
        case .tabs: ["tabs.willSet"]
        case .workspaceGroups: ["groups.willSet"]
        case .selectedTabId: ["selection.willSet", "selection.didSet"]
        }
    }

    @MainActor
    func read(_ model: WorkspacesModel<ObservedStubTab>) {
        switch self {
        case .tabs: _ = model.tabs
        case .workspaceGroups: _ = model.workspaceGroups
        case .selectedTabId: _ = model.selectedTabId
        }
    }

    @MainActor
    func change(_ model: WorkspacesModel<ObservedStubTab>) {
        switch self {
        case .tabs:
            model.tabs = [ObservedStubTab()]
        case .workspaceGroups:
            model.workspaceGroups = [Self.group(named: "changed")]
        case .selectedTabId:
            model.selectedTabId = UUID()
        }
    }

    static func group(named name: String) -> WorkspaceGroup {
        WorkspaceGroup(
            id: UUID(),
            name: name,
            isCollapsed: false,
            isPinned: false,
            anchorWorkspaceId: UUID(),
            customColor: nil,
            iconSymbol: nil
        )
    }
}
