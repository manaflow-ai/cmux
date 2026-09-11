import CmuxNotifications
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
    /// Present when this row renders through the pure-AppKit workspace cell.
    let appKitWorkspaceRowModel: SidebarWorkspaceRowModel?
    let appKitWorkspaceRowActions: SidebarAppKitRowActions?
    /// Live workspace reference + fresh-model factory for the per-row churn
    /// pump (metadata/branch/PR updates repaint one cell, no container render).
    let appKitWorkspaceRowWorkspace: Workspace?
    let appKitWorkspaceRowRebuild: (@MainActor () -> SidebarWorkspaceRowModel)?
    /// Workspace ids whose unread summaries affect this row, plus factories
    /// that repaint only the matching AppKit cell from the latest atomic
    /// unread snapshot. They are intentionally excluded from row equality.
    let appKitUnreadDependencyWorkspaceIds: Set<UUID>
    let appKitWorkspaceUnreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarWorkspaceRowModel)?
    let appKitGroupHeaderUnreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarGroupHeaderRowModel)?

    private let environment: SidebarWorkspaceTableEnvironmentSnapshot
    private let equivalenceValue: Any
    private let isEquivalentValue: (Any) -> Bool
    private let isHeightEquivalentValue: (Any) -> Bool

    private init(
        id: SidebarWorkspaceRenderItemID,
        workspaceId: UUID,
        groupId: UUID?,
        isGroupHeader: Bool,
        isPinned: Bool,
        makeContent: @escaping ContentFactory,
        appKitGroupHeaderModel: SidebarGroupHeaderRowModel?,
        appKitWorkspaceRowModel: SidebarWorkspaceRowModel?,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        equivalenceValue: Any,
        isEquivalentValue: @escaping (Any) -> Bool,
        isHeightEquivalentValue: ((Any) -> Bool)? = nil
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.groupId = groupId
        self.isGroupHeader = isGroupHeader
        self.isPinned = isPinned
        self.makeContent = makeContent
        self.appKitGroupHeaderModel = appKitGroupHeaderModel
        self.appKitGroupHeaderActions = nil
        self.appKitWorkspaceRowModel = appKitWorkspaceRowModel
        self.appKitWorkspaceRowActions = nil
        self.appKitWorkspaceRowWorkspace = nil
        self.appKitWorkspaceRowRebuild = nil
        self.appKitUnreadDependencyWorkspaceIds = []
        self.appKitWorkspaceUnreadRebuild = nil
        self.appKitGroupHeaderUnreadRebuild = nil
        self.environment = environment
        self.equivalenceValue = equivalenceValue
        self.isEquivalentValue = isEquivalentValue
        self.isHeightEquivalentValue = isHeightEquivalentValue ?? isEquivalentValue
    }

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
        self.appKitUnreadDependencyWorkspaceIds = []
        self.appKitWorkspaceUnreadRebuild = nil
        self.appKitGroupHeaderUnreadRebuild = nil
        self.equivalenceValue = equivalenceValue
        self.isEquivalentValue = { value in
            guard let value = value as? Content else { return false }
            return value == equivalenceValue
        }
        self.isHeightEquivalentValue = self.isEquivalentValue
    }

    init(
        groupHeaderModel: SidebarGroupHeaderRowModel,
        actions: SidebarGroupHeaderRowActions,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        unreadDependencyWorkspaceIds: Set<UUID> = [],
        unreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarGroupHeaderRowModel)? = nil
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
        self.appKitUnreadDependencyWorkspaceIds = unreadDependencyWorkspaceIds
        self.appKitWorkspaceUnreadRebuild = nil
        self.appKitGroupHeaderUnreadRebuild = unreadRebuild
        self.equivalenceValue = groupHeaderModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarGroupHeaderRowModel else { return false }
            return value == groupHeaderModel
        }
        self.isHeightEquivalentValue = self.isEquivalentValue
    }

    init(
        workspaceRowModel: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        groupId: UUID?,
        isPinned: Bool,
        environment: SidebarWorkspaceTableEnvironmentSnapshot,
        workspace: Workspace? = nil,
        rebuild: (@MainActor () -> SidebarWorkspaceRowModel)? = nil,
        unreadRebuild: (@MainActor (SidebarUnreadSnapshot) -> SidebarWorkspaceRowModel)? = nil
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
        self.appKitUnreadDependencyWorkspaceIds = [workspaceRowModel.workspaceId]
        self.appKitWorkspaceUnreadRebuild = unreadRebuild
        self.appKitGroupHeaderUnreadRebuild = nil
        self.equivalenceValue = workspaceRowModel
        self.isEquivalentValue = { value in
            guard let value = value as? SidebarWorkspaceRowModel else { return false }
            return value == workspaceRowModel
        }
        self.isHeightEquivalentValue = { value in
            guard let value = value as? SidebarWorkspaceRowModel else { return false }
            return value.hasHeightEquivalentContent(to: workspaceRowModel)
        }
    }

    func hasEquivalentContent(to other: Self) -> Bool {
        environment.hasEquivalentPresentation(to: other.environment)
            && isEquivalentValue(other.equivalenceValue)
    }

    /// Content equality restricted to fields that can change the measured row
    /// height. The height cache keys on this: a close shifts `index` /
    /// `isFirstRow` for every row below it, and treating those rows as changed
    /// would both re-measure the whole tail and drop the content-matched
    /// entries the stale-width `height(for:)` fallback depends on.
    func hasEquivalentHeightContent(to other: Self) -> Bool {
        environment.hasEquivalentPresentation(to: other.environment)
            && isHeightEquivalentValue(other.equivalenceValue)
    }

    func applyingUnreadSnapshot(_ snapshot: SidebarUnreadSnapshot) -> Self {
        if let rebuild = appKitWorkspaceUnreadRebuild,
           let actions = appKitWorkspaceRowActions {
            let model = rebuild(snapshot)
            guard model != appKitWorkspaceRowModel else { return self }
            return Self(
                workspaceRowModel: model,
                actions: actions,
                groupId: groupId,
                isPinned: isPinned,
                environment: environment,
                workspace: appKitWorkspaceRowWorkspace,
                rebuild: appKitWorkspaceRowRebuild,
                unreadRebuild: rebuild
            )
        }
        if let rebuild = appKitGroupHeaderUnreadRebuild,
           let actions = appKitGroupHeaderActions {
            let model = rebuild(snapshot)
            guard model != appKitGroupHeaderModel else { return self }
            return Self(
                groupHeaderModel: model,
                actions: actions,
                environment: environment,
                unreadDependencyWorkspaceIds: appKitUnreadDependencyWorkspaceIds,
                unreadRebuild: rebuild
            )
        }
        return self
    }

    /// Keeps the immutable paint model while dropping every live action,
    /// workspace, and hosted-content capture during retained hidden display.
    func presentationSnapshot() -> Self {
        Self(
            id: id,
            workspaceId: workspaceId,
            groupId: groupId,
            isGroupHeader: isGroupHeader,
            isPinned: isPinned,
            makeContent: { _, _ in AnyView(EmptyView()) },
            appKitGroupHeaderModel: appKitGroupHeaderModel,
            appKitWorkspaceRowModel: appKitWorkspaceRowModel,
            environment: environment,
            equivalenceValue: id,
            isEquivalentValue: { ($0 as? SidebarWorkspaceRenderItemID) == id }
        )
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
