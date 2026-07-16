import SwiftUI

struct SidebarWorkspaceTableContextMenuActions {
    let didOpen: () -> Void
    let didClose: () -> Void
}

/// Immutable description of one AppKit-owned sidebar row.
@MainActor
struct SidebarWorkspaceTableRowConfiguration {
    typealias ContentFactory = (
        _ isPointerHovering: Bool,
        _ contextMenuActions: SidebarWorkspaceTableContextMenuActions
    ) -> AnyView

    let id: SidebarWorkspaceRenderItemID
    let workspaceId: UUID
    let groupId: UUID?
    let isGroupHeader: Bool
    let isPinned: Bool
    let makeContent: ContentFactory
    /// Present when this row renders through the pure-AppKit group header cell
    /// instead of a hosted SwiftUI cell.
    let appKitGroupHeaderModel: SidebarGroupHeaderRowModel?
    let appKitGroupHeaderActions: SidebarGroupHeaderRowActions?

    private let environment: SidebarWorkspaceTableEnvironmentSnapshot
    private let equivalenceValue: Any
    private let isEquivalentValue: (Any) -> Bool

    init<Content: View & Equatable>(
        id: SidebarWorkspaceRenderItemID,
        workspaceId: UUID,
        groupId: UUID?,
        isGroupHeader: Bool,
        isPinned: Bool,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        equivalenceValue: Content,
        makeContent: @escaping ContentFactory
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isGroupHeader = isGroupHeader
        self.isPinned = isPinned
        self.environment = environment
        self.makeContent = makeContent
        self.appKitGroupHeaderModel = nil
        self.appKitGroupHeaderActions = nil
        self.equivalenceValue = equivalenceValue
        self.isEquivalentValue = { value in
            guard let value = value as? Content else { return false }
            return value == equivalenceValue
        }
    }

    init(
        groupHeaderModel: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions,
        environment: SidebarWorkspaceTableEnvironmentSnapshot
    ) {
        self.id = .group(groupHeaderModel.groupId)
        self.workspaceId = groupHeaderModel.anchorWorkspaceId
        self.groupId = groupHeaderModel.groupId
        self.isGroupHeader = true
        self.isPinned = groupHeaderModel.isPinned
        self.environment = environment
        self.makeContent = { _, _ in AnyView(EmptyView()) }
        self.appKitGroupHeaderModel = groupHeaderModel
        self.appKitGroupHeaderActions = actions
        self.equivalenceValue = groupHeaderModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarGroupHeaderRowModel else { return false }
            return value == groupHeaderModel
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
