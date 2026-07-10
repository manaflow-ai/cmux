import CmuxMobileShellModel
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceListView {
    static let workspaceDropCoordinateSpace = "MobileWorkspaceDropList"

    /// Pipelining bound: with reorder enabled during pending moves, a slow or
    /// offline Mac must not let the send chain grow without limit, and every
    /// queued move currently costs a full workspace refresh on reply. Normal
    /// round-trips resolve between drags, so this only bites when the host is
    /// genuinely unresponsive.
    static let maxPipelinedWorkspaceMoves = 3

    var enablesWorkspaceReorder: Bool {
        moveWorkspace != nil
            && pendingWorkspaceMoveCount < Self.maxPipelinedWorkspaceMoves
            && canRenderGroupsForSelection
            && trimmedQuery.isEmpty
            && filter.readState == .all
            && filter.machines.isEmpty
            && reorderableWorkspaces.hasSingleKnownWindow
            && (rendersGroupedSections || !filteredWorkspaces.contains(where: \.isPinned))
    }

    var reorderableWorkspaces: [MobileWorkspacePreview] {
        rendersGroupedSections ? groupedWorkspaces : filteredWorkspaces
    }

    var filteredWorkspaceOrderKey: [WorkspaceListStableOrderKey] {
        filteredWorkspaces.map { WorkspaceListStableOrderKey(workspace: $0) }
    }

    var groupedWorkspaceOrderKey: [WorkspaceListStableOrderKey] {
        groupedListItems.map { WorkspaceListStableOrderKey(item: $0) }
    }

    var canCreateWorkspaceInGroups: Bool {
        createWorkspaceInGroup != nil
            && canCreateWorkspaceForMacSelection
            && canRenderGroupsForSelection
    }

    func syncOptimisticWorkspaceOrder(moveDidFail: Bool = false) {
        let hadPendingOptimism = optimisticFlatState.optimisticOrder != nil
            || optimisticGroupedState.optimisticOrder != nil
        optimisticFlatState = optimisticFlatState.reconciling(
            authoritative: filteredWorkspaces,
            moveDidFail: moveDidFail
        )
        optimisticGroupedState = optimisticGroupedState.reconciling(
            authoritative: groupedWorkspaces,
            groups: groups,
            moveDidFail: moveDidFail
        )
        let cleared = optimisticFlatState.optimisticOrder == nil
            && optimisticGroupedState.optimisticOrder == nil
        // A supersede (or failure) invalidates every queued dependent: their
        // intents were computed against predictions the host has overruled.
        // Bumping the epoch makes not-yet-sent moves abort, and detaching the
        // tail lets fresh drags start a clean chain.
        if hadPendingOptimism, cleared, pendingWorkspaceMoveCount > 0 {
            workspaceMoveEpoch &+= 1
            pendingWorkspaceMoveTask = nil
        }
    }

    func beginWorkspaceDrag(_ payload: MobileWorkspaceDropPayload) -> NSItemProvider {
        workspaceDropState.payload = payload
        workspaceDropState.target = nil
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return NSItemProvider(
            item: data as NSData,
            typeIdentifier: UTType.cmuxWorkspaceListMove.identifier
        )
    }

    func commitWorkspaceDrop(
        payload: MobileWorkspaceDropPayload,
        intent: MobileWorkspaceMoveIntent
    ) {
        guard enablesWorkspaceReorder else { return }
        guard payload.isGroupDrag == intent.movesGroup else { return }
        let sourceWorkspaces = rendersGroupedSections
            ? displayedGroupedWorkspaces
            : displayedFlatWorkspaces
        let sourceGroups = rendersGroupedSections ? groups : []
        let movedWorkspaces = sourceWorkspaces.applyingWorkspaceMoveIntent(
            intent,
            movedWorkspaceID: payload.workspaceID,
            groups: sourceGroups
        )
        if rendersGroupedSections {
            optimisticGroupedState = MobileWorkspaceOptimisticOrderReconciler(
                optimisticOrder: MobileWorkspaceOptimisticOrder(workspaces: movedWorkspaces, groups: groups),
                pendingBases: optimisticGroupedState.pendingBases
                    + [MobileWorkspaceOptimisticOrder(workspaces: sourceWorkspaces, groups: groups)]
            )
        } else {
            optimisticFlatState = MobileWorkspaceOptimisticOrderReconciler(
                optimisticOrder: MobileWorkspaceOptimisticOrder(workspaces: movedWorkspaces),
                pendingBases: optimisticFlatState.pendingBases
                    + [MobileWorkspaceOptimisticOrder(workspaces: sourceWorkspaces)]
            )
        }
        enqueueWorkspaceMove(payload.workspaceID, intent: intent)
    }

    private func enqueueWorkspaceMove(
        _ movedWorkspaceID: MobileWorkspacePreview.ID,
        intent: MobileWorkspaceMoveIntent
    ) {
        pendingWorkspaceMoveCount += 1
        let previousMove = pendingWorkspaceMoveTask
        let epoch = workspaceMoveEpoch
        pendingWorkspaceMoveTask = Task { @MainActor in
            // Intents are computed against the prior prediction, so sends stay
            // serialized and abort after predecessor failure or epoch change.
            if let previousMove, await previousMove.value == false {
                pendingWorkspaceMoveCount -= 1
                return false
            }
            guard epoch == workspaceMoveEpoch else {
                pendingWorkspaceMoveCount -= 1
                return false
            }
            let accepted = await moveWorkspace?(
                movedWorkspaceID,
                intent.groupID,
                intent.beforeWorkspaceID,
                intent.movesGroup
            ) ?? false
            pendingWorkspaceMoveCount -= 1
            if !accepted {
                syncOptimisticWorkspaceOrder(moveDidFail: true)
                // Dependents retain the failed task and abort; fresh drags can
                // start a detached chain after rollback.
                pendingWorkspaceMoveTask = nil
            }
            return accepted
        }
    }

    /// Scrolls one row per edge-zone update. A stationary finger does not keep
    /// scrolling because v1 intentionally follows `dropUpdated` cadence only.
    func autoScrollWorkspaceDrop(
        point: CGPoint,
        viewportSize: CGSize,
        rows: [MobileWorkspaceDropRowFrame],
        orderedRowIDs: [String],
        proxy: ScrollViewProxy
    ) {
        let visibleRows = rows.filter {
            $0.frame.maxY > 0 && $0.frame.minY < viewportSize.height
        }.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = visibleRows.first, let last = visibleRows.last else { return }
        if point.y < 60,
           let index = orderedRowIDs.firstIndex(of: first.kind.stableID),
           index > orderedRowIDs.startIndex {
            proxy.scrollTo(orderedRowIDs[index - 1], anchor: .top)
        } else if point.y > viewportSize.height - 60,
                  let index = orderedRowIDs.firstIndex(of: last.kind.stableID),
                  index + 1 < orderedRowIDs.endIndex {
            proxy.scrollTo(orderedRowIDs[index + 1], anchor: .bottom)
        }
    }
}

struct WorkspaceListStableOrderKey: Equatable {
    let rowID: String
    let workspaceID: MobileWorkspacePreview.ID?
    let groupID: MobileWorkspaceGroupPreview.ID?
    let windowID: String?
    let macDeviceID: String?
    let isPinned: Bool?
    let isGroupCollapsed: Bool?

    init(workspace: MobileWorkspacePreview) {
        rowID = "workspace.\(workspace.id.rawValue)"
        workspaceID = workspace.id
        groupID = workspace.groupID
        windowID = workspace.windowID
        macDeviceID = workspace.macDeviceID
        isPinned = workspace.isPinned
        isGroupCollapsed = nil
    }

    init(item: MobileWorkspaceListItem) {
        rowID = item.id
        switch item {
        case .workspace(let workspace, _):
            workspaceID = workspace.id
            groupID = workspace.groupID
            windowID = workspace.windowID
            macDeviceID = workspace.macDeviceID
            isPinned = workspace.isPinned
            isGroupCollapsed = nil
        case .groupHeader(let group, _):
            workspaceID = group.anchorWorkspaceID
            groupID = group.id
            windowID = nil
            macDeviceID = nil
            isPinned = group.isPinned
            isGroupCollapsed = group.isCollapsed
        }
    }
}
