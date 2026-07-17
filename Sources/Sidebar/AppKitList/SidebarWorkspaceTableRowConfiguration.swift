import SwiftUI

/// Immutable description of one AppKit-owned sidebar row.
@MainActor
struct SidebarWorkspaceTableRowConfiguration {
    typealias ContentFactory = (
        _ isPointerHovering: Bool,
        _ contextMenuActions: SidebarWorkspaceTableContextMenuActions,
        _ editingDidChange: @escaping (Bool) -> Void
    ) -> AnyView

    let id: SidebarWorkspaceRenderItemID
    let workspaceId: UUID
    let groupId: UUID?
    let isGroupHeader: Bool
    let isPinned: Bool
    let makeContent: ContentFactory

    private let environment: SidebarWorkspaceTableEnvironmentSnapshot
    private let equivalenceValue: Any
    private let isEquivalentValue: (Any) -> Bool

    init<Value: Equatable>(
        id: SidebarWorkspaceRenderItemID,
        workspaceId: UUID,
        groupId: UUID?,
        isGroupHeader: Bool,
        isPinned: Bool,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        equivalenceValue: Value,
        makeContent: @escaping ContentFactory
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isGroupHeader = isGroupHeader
        self.isPinned = isPinned
        self.environment = environment
        self.makeContent = makeContent
        self.equivalenceValue = equivalenceValue
        self.isEquivalentValue = { value in
            guard let value = value as? Value else { return false }
            return value == equivalenceValue
        }
    }

    func hasEquivalentContent(to other: Self) -> Bool {
        environment.hasEquivalentPresentation(to: other.environment)
            && isEquivalentValue(other.equivalenceValue)
    }

    var estimatedHeight: CGFloat {
        let fontScale = CGFloat(environment.globalFontMagnificationPercent) / 100
        let calculator = SidebarWorkspaceTableRowHeightCalculator()
        if isGroupHeader {
            return calculator.estimatedGroupHeaderHeight(fontScale: fontScale)
        }
        return calculator.estimatedWorkspaceHeight(
            fontScale: fontScale,
            titleLineCount: 1,
            auxiliaryLineCount: 0
        )
    }
}
