import SwiftUI

struct SidebarWorkspaceTableContextMenuActions {
    let didOpen: () -> Void
    let didClose: () -> Void
}

/// Mutable, non-observed holder for the last-built table rows. The sidebar
/// container freezes row building against it during interactive divider
/// drags (rows cannot change while the resizer owns the mouse), so
/// per-width-tick body evals skip the row-projection prelude.
@MainActor
final class SidebarAppKitFrozenRowsBox {
    var rows: [SidebarWorkspaceTableRowConfiguration]?
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
    /// Present when this row renders through the pure-AppKit workspace cell.
    let appKitWorkspaceRowModel: SidebarWorkspaceRowModel?
    let appKitWorkspaceRowActions: SidebarAppKitRowActions?
    /// Live workspace reference + fresh-model factory for the per-row churn
    /// pump (metadata/branch/PR updates repaint one cell, no container render).
    let appKitWorkspaceRowWorkspace: Workspace?
    let appKitWorkspaceRowRebuild: (@MainActor () -> SidebarWorkspaceRowModel)?

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
        self.appKitWorkspaceRowModel = nil
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
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
        self.appKitWorkspaceRowModel = nil
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
        self.equivalenceValue = groupHeaderModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarGroupHeaderRowModel else { return false }
            return value == groupHeaderModel
        }
    }

    init(
        workspaceRowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        groupId: UUID?,
        isPinned: Bool,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        workspace: Workspace? = nil,
        rebuild: (@MainActor () -> SidebarWorkspaceRowModel)? = nil
    ) {
        self.id = .workspace(workspaceRowModel.workspaceId)
        self.workspaceId = workspaceRowModel.workspaceId
        self.groupId = groupId
        self.isGroupHeader = false
        self.isPinned = isPinned
        self.environment = environment
        self.makeContent = { _, _ in AnyView(EmptyView()) }
        self.appKitGroupHeaderModel = nil
        self.appKitGroupHeaderActions = nil
        self.appKitWorkspaceRowModel = workspaceRowModel
        self.appKitWorkspaceRowActions = actions
        self.appKitWorkspaceRowWorkspace = workspace
        self.appKitWorkspaceRowRebuild = rebuild
        self.equivalenceValue = workspaceRowModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarWorkspaceRowModel else { return false }
            return value == workspaceRowModel
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
