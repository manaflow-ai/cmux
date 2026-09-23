#if os(iOS)
import CmuxMobileShellModel

/// Everything one workspace-table row renders, derived from a
/// ``WorkspaceListTable`` snapshot.
///
/// The table compares these values, never the snapshot, to decide what a live
/// update touches. Each case holds exactly its hosted view's inputs, and
/// callbacks are reduced to availability flags: the cell's closures forward to
/// the coordinator's latest configuration when invoked, so a changed closure
/// identity never needs a re-render.
enum WorkspaceListRowModel: Equatable {
    case workspace(WorkspaceListWorkspaceRowModel)
    case groupHeader(WorkspaceGroupHeaderRowValue)
    case groupFooter(groupName: String?, showsBoundary: Bool)
    case recoveryBanner(requiresReauth: Bool, error: String?, canSignOut: Bool)
    case macStatus(WorkspaceListMacStatusRowModel)
    case filterEmpty(MobileWorkspaceListFilter)
    case emptyWorkspaceList(WorkspaceListEmptyRowModel)
    /// The snapshot names a row whose workspace or group it does not carry.
    case missing
}

struct WorkspaceListWorkspaceRowModel: Equatable {
    let content: WorkspaceRowContent
    let isIndented: Bool
    let accessibilityValue: String
    let canCustomize: Bool
    let canRename: Bool
    let canTogglePin: Bool
}

struct WorkspaceListMacStatusRowModel: Equatable {
    let host: String
    let status: MobileMacConnectionStatus
    let showsSpinner: Bool
    let titleOverride: String?
    let descriptionOverride: String?
    let canRetry: Bool
    let canAddDevice: Bool
    let canReconnect: Bool
}

struct WorkspaceListEmptyRowModel: Equatable {
    let isVisible: Bool
    let hasRetry: Bool
    let ownerID: String?
    let ownerInstanceTag: String?
}

/// What UIKit caches from a row outside its content view: the swipe actions
/// and the accessibility actions it derives from them. A change here needs a
/// real row reload, because reconfiguring content does not refresh that cache.
struct WorkspaceListNativeActionKey: Equatable {
    let hasUnread: Bool
    let supportsReadState: Bool
    let supportsClose: Bool
    let canSetUnread: Bool
    let canClose: Bool
}

/// Identifies the inputs of a shared row height. Rows sharing a key share one
/// measurement; content outside the key (preview text, timestamps without
/// title wrapping, unread counts, colors) is height-neutral by construction,
/// because the row reserves its preview and description lines. Chrome and
/// empty-state rows are measured individually instead.
enum WorkspaceListRowLayoutKey: Hashable {
    case workspace(WorkspaceListWorkspaceLayoutKey)
    case groupHeader
}

struct WorkspaceListWorkspaceLayoutKey: Hashable {
    /// Title-line inputs, present only when titles wrap. The timestamp and pin
    /// share the title's line, so they change where it wraps.
    struct WrappedTitle: Hashable {
        let name: String
        let timestampText: String
        let isPinned: Bool
    }

    let wrappedTitle: WrappedTitle?
    let isSelected: Bool
    let isIndented: Bool
    let hasDescription: Bool
    let changesChip: WorkspaceChangesChipHeightKey?
    let previewLineLimit: Int
    let unreadBadgeDiameter: Double

    init(_ model: WorkspaceListWorkspaceRowModel) {
        let content = model.content
        wrappedTitle = content.wrapWorkspaceTitles
            ? WrappedTitle(
                name: content.name,
                timestampText: content.timestampText,
                isPinned: content.isPinned
            )
            : nil
        isSelected = content.isSelected
        isIndented = model.isIndented
        hasDescription = content.description != nil
        changesChip = content.changesChip.map {
            WorkspaceChangesChipHeightKey(
                filesChanged: $0.filesChanged,
                additions: $0.additions,
                deletions: $0.deletions,
                isInteractive: content.opensChanges
            )
        }
        previewLineLimit = content.previewLineLimit
        unreadBadgeDiameter = content.unreadBadgeDiameter
    }
}

extension WorkspaceListTable {
    /// The rendered model of `item` in this snapshot.
    @MainActor
    func rowModel(
        for item: WorkspaceListTableItem,
        showsGroupBoundaries: Bool
    ) -> WorkspaceListRowModel {
        switch item {
        case .workspace(let id, let indented):
            guard let workspace = workspacesByID[id] else { return .missing }
            let connectionStatus = workspace.macConnectionStatus ?? self.connectionStatus
            let changesChip = workspaceChangesCapable
                ? workspaceChangeChipsByWorkspaceID[workspace.rpcWorkspaceID.rawValue]
                : nil
            let capabilities = workspace.actionCapabilities
            return .workspace(
                WorkspaceListWorkspaceRowModel(
                    content: WorkspaceRowContent(
                        workspace: workspace,
                        connectionStatus: connectionStatus,
                        isSelected: navigationStyle == .sidebar && selectedWorkspaceID == id,
                        changesChip: changesChip,
                        opensChanges: openWorkspaceChanges != nil,
                        wrapWorkspaceTitles: wrapWorkspaceTitles,
                        previewLineLimit: previewLineLimit,
                        unreadIndicatorLeftShift: unreadIndicatorLeftShift,
                        unreadBadgeDiameter: unreadBadgeDiameter
                    ),
                    isIndented: indented,
                    accessibilityValue: workspace.accessibilitySummary(
                        connectionStatus: connectionStatus
                    ),
                    canCustomize: capabilities.supportsWorkspaceActions
                        && capabilities.supportsWorkspaceMetadata
                        && customizeRequest != nil,
                    canRename: capabilities.supportsWorkspaceActions && renameRequest != nil,
                    canTogglePin: capabilities.supportsWorkspaceActions && setPinned != nil
                )
            )
        case .groupHeader(let groupID):
            guard let group = groupsByID[groupID] else { return .missing }
            let capabilities = groupActionCapabilities(for: group)
            return .groupHeader(
                WorkspaceGroupHeaderRowValue(
                    group: group,
                    unread: groupUnreadByID[groupID, default: .read],
                    navigationStyle: navigationStyle,
                    isAnchorSelected: navigationStyle == .sidebar
                        && selectedWorkspaceID == group.liveAnchorWorkspaceID,
                    canCreateWorkspaceInGroup: createWorkspaceInGroup != nil,
                    canRenameGroup: capabilities.supportsGroupActions
                        && renameWorkspaceGroup != nil,
                    canSetGroupPinned: capabilities.supportsGroupActions
                        && setGroupPinned != nil,
                    canUngroupWorkspaceGroup: !group.isPinned
                        && capabilities.supportsGroupActions
                        && ungroupWorkspaceGroup != nil,
                    canDeleteWorkspaceGroup: capabilities.supportsGroupActions
                        && deleteWorkspaceGroup != nil,
                    canToggleCollapsed: toggleGroupCollapsed != nil,
                    unreadIndicatorLeftShift: unreadIndicatorLeftShift,
                    unreadBadgeDiameter: unreadBadgeDiameter
                )
            )
        case .groupFooter(let groupID):
            return .groupFooter(
                groupName: groupsByID[groupID]?.name,
                showsBoundary: showsGroupBoundaries
            )
        case .chrome(.recoveryBanner):
            return .recoveryBanner(
                requiresReauth: connectionRequiresReauth,
                error: connectionError,
                canSignOut: signOut != nil
            )
        case .chrome(.macStatusRow):
            return .macStatus(
                WorkspaceListMacStatusRowModel(
                    host: host,
                    status: connectionStatus,
                    showsSpinner: isInitialConnectionLoading,
                    titleOverride: initialConnectionTitle,
                    descriptionOverride: initialConnectionDescription,
                    canRetry: retryInitialConnection != nil,
                    canAddDevice: showAddDevice != nil,
                    canReconnect: reconnect != nil
                )
            )
        case .filterEmpty:
            return .filterEmpty(filter)
        case .emptyWorkspaceList:
            return .emptyWorkspaceList(
                WorkspaceListEmptyRowModel(
                    isVisible: showsWorkspaceEmptyState,
                    hasRetry: refresh != nil,
                    ownerID: workspaceOwnerID,
                    ownerInstanceTag: workspaceOwnerInstanceTag
                )
            )
        }
    }

    /// The native swipe identity of `item`, or `nil` when it has no swipes.
    func nativeActionKey(for item: WorkspaceListTableItem) -> WorkspaceListNativeActionKey? {
        let workspace: MobileWorkspacePreview?
        switch item {
        case .workspace(let id, _):
            workspace = workspacesByID[id]
        case .groupHeader(let groupID):
            workspace = groupsByID[groupID]?.liveAnchorWorkspaceID
                .flatMap { workspacesByID[$0] }
        case .chrome, .groupFooter, .filterEmpty, .emptyWorkspaceList:
            return nil
        }
        guard let workspace else { return nil }
        return WorkspaceListNativeActionKey(
            hasUnread: workspace.hasUnread,
            supportsReadState: workspace.actionCapabilities.supportsReadStateActions,
            supportsClose: workspace.actionCapabilities.supportsCloseActions,
            canSetUnread: setUnread != nil,
            canClose: closeWorkspace != nil
        )
    }

    /// Group actions are owned by the Mac connection, not by a particular
    /// workspace row. The group snapshot carries that Mac-scoped capability,
    /// including when the group has no live anchor row.
    func groupActionCapabilities(
        for group: MobileWorkspaceGroupPreview
    ) -> MobileWorkspaceActionCapabilities {
        if let capabilities = group.actionCapabilities {
            return capabilities
        }
        if let anchorWorkspaceID = group.liveAnchorWorkspaceID,
           let capabilities = workspacesByID[anchorWorkspaceID]?.actionCapabilities {
            return capabilities
        }
        return .none
    }
}

#endif
