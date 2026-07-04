import CmuxWorkspaces
import Foundation

/// Window-side entry points for the top-level "Workstreams" drill-in feature.
/// These forward to `WorkstreamCoordinator` (pure model logic in CmuxWorkspaces)
/// and own only the localized auto-name format — the single piece that must
/// stay app-side so `String(localized:)` resolves against the app bundle.
extension TabManager {
    /// Localized "Workstream %lld" auto-name format used when the user creates
    /// a workstream without typing a name.
    var localizedAutoWorkstreamNameFormat: String {
        String(
            localized: "workstream.autoName.numbered",
            defaultValue: "Workstream %lld"
        )
    }

    @discardableResult
    func createWorkstream(name: String, memberWorkspaceIds: [UUID] = []) -> UUID {
        workstreamCoordinator.createWorkstream(
            name: name,
            memberWorkspaceIds: memberWorkspaceIds,
            autoNameFormat: localizedAutoWorkstreamNameFormat
        )
    }

    func renameWorkstream(id: UUID, name: String) {
        workstreamCoordinator.renameWorkstream(id: id, name: name)
    }

    @discardableResult
    func deleteWorkstream(id: UUID) -> Int {
        workstreamCoordinator.deleteWorkstream(id: id)
    }

    func addWorkspaceToWorkstream(workspaceId: UUID, workstreamId: UUID) {
        workstreamCoordinator.addWorkspaceToWorkstream(workspaceId: workspaceId, workstreamId: workstreamId)
    }

    func removeWorkspaceFromWorkstream(workspaceId: UUID) {
        workstreamCoordinator.removeWorkspaceFromWorkstream(workspaceId: workspaceId)
    }

    func workspaceGroupMemberIds(groupId: UUID, visibleInWorkstreamId workstreamId: UUID?) -> [UUID] {
        tabs.compactMap { workspace in
            workspace.groupId == groupId && workspace.workstreamId == workstreamId ? workspace.id : nil
        }
    }

    func sidebarScopedWorkspaceRowIds() -> [UUID] {
        SidebarWorkspaceRenderItem.rowWorkspaceIds(
            tabs: tabs.filter { $0.workstreamId == drilledInWorkstreamId },
            groupsById: Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        )
    }

    func sidebarScopedWorkspaceIndex(tabId: UUID) -> Int? {
        sidebarScopedWorkspaceRowIds().firstIndex(of: tabId)
    }

    func moveWorkspaceInSidebarScope(tabId: UUID, by delta: Int) -> Bool {
        let visibleIds = sidebarScopedWorkspaceRowIds()
        guard delta != 0, let visibleIndex = visibleIds.firstIndex(of: tabId),
              visibleIds.indices.contains(visibleIndex + delta) else { return false }
        let peerIndex = visibleIndex + delta
        let peerId = visibleIds[peerIndex]
        if delta < 0 {
            return reorderWorkspace(tabId: tabId, before: peerId)
        }
        if visibleIds.indices.contains(peerIndex + 1) {
            return reorderWorkspace(tabId: tabId, before: visibleIds[peerIndex + 1])
        }
        return reorderWorkspace(tabId: tabId, after: peerId)
    }

    func workspaceIdsForClosingOtherSidebarRows(keeping keepIds: Set<UUID>) -> [UUID] {
        let visibleIds = sidebarScopedWorkspaceRowIds()
        guard !keepIds.isDisjoint(with: Set(visibleIds)) else { return [] }
        return visibleIds.filter { !keepIds.contains($0) }
    }

    func workspaceIdsForClosingSidebarRowsBelow(tabId: UUID) -> [UUID] {
        let visibleIds = sidebarScopedWorkspaceRowIds()
        guard let anchorIndex = visibleIds.firstIndex(of: tabId) else { return [] }
        return Array(visibleIds.suffix(from: anchorIndex + 1))
    }

    func workspaceIdsForClosingSidebarRowsAbove(tabId: UUID) -> [UUID] {
        let visibleIds = sidebarScopedWorkspaceRowIds()
        guard let anchorIndex = visibleIds.firstIndex(of: tabId) else { return [] }
        return Array(visibleIds.prefix(upTo: anchorIndex))
    }

    func fallbackSelectedWorkspaceIdAfterClosingWorkspace(at removedIndex: Int) -> UUID {
        if drilledInWorkstreamId != nil {
            let scopedIndices = tabs.indices.filter { tabs[$0].workstreamId == drilledInWorkstreamId }
            if let scopedIndex = scopedIndices.first(where: { $0 >= removedIndex }) ?? scopedIndices.last {
                return tabs[scopedIndex].id
            }
            exitWorkstreamDrillIn()
        }
        return tabs[min(removedIndex, max(0, tabs.count - 1))].id
    }

    @discardableResult
    func deleteWorkspaceGroupMembers(groupId: UUID, visibleInWorkstreamId workstreamId: UUID?, recordHistory: Bool = true) -> Int {
        guard workspaceGroups.contains(where: { $0.id == groupId }) else { return 0 }
        let memberIds = workspaceGroupMemberIds(groupId: groupId, visibleInWorkstreamId: workstreamId)
        var closed = 0
        for id in memberIds {
            guard let workspace = tabs.first(where: { $0.id == id }) else { continue }
            if tabs.count <= 1 {
                workspace.groupId = nil
                workspaceGroups.removeAll { $0.id == groupId }
                continue
            }
            let countBefore = tabs.count
            closeWorkspace(workspace, recordHistory: recordHistory)
            if tabs.count < countBefore {
                closed += 1
            }
        }
        if !tabs.contains(where: { $0.groupId == groupId }) {
            workspaceGroups.removeAll { $0.id == groupId }
        }
        return closed
    }

    func moveWorkstream(id: UUID, toIndex targetIndex: Int) {
        workstreamCoordinator.moveWorkstream(id: id, toIndex: targetIndex)
    }

    func setWorkstreamColor(id: UUID, hex: String?) {
        workstreamCoordinator.setWorkstreamColor(id: id, hex: hex)
    }

    func setWorkstreamIcon(id: UUID, symbol: String?) {
        workstreamCoordinator.setWorkstreamIcon(id: id, symbol: symbol)
    }

    /// Drill into a workstream (sidebar shows only its workspaces).
    func enterWorkstream(id: UUID) {
        guard workstreams.contains(where: { $0.id == id }) else { return }
        workstreamCoordinator.enterWorkstream(id: id)
        pruneSidebarSelectionForCurrentWorkstreamScope()
    }

    /// Return to the top-level workstream list.
    func exitWorkstreamDrillIn() {
        workstreamCoordinator.exitWorkstreamDrillIn()
        pruneSidebarSelectionForCurrentWorkstreamScope()
    }

    private func pruneSidebarSelectionForCurrentWorkstreamScope() {
        let visibleWorkspaceIds = Set(tabs.compactMap { workspace in
            workspace.workstreamId == drilledInWorkstreamId ? workspace.id : nil
        })
        let hiddenSelectedIds = sidebarSelectedWorkspaceIds.subtracting(visibleWorkspaceIds)
        guard !hiddenSelectedIds.isEmpty else { return }
        sidebarMultiSelection.subtractSelection(hiddenSelectedIds)
        let focusedWorkspaceId = selectedTabId.flatMap { visibleWorkspaceIds.contains($0) ? $0 : nil }
        sidebarMultiSelection.postDidHide(
            hiddenWorkspaceIds: hiddenSelectedIds,
            focusedWorkspaceId: focusedWorkspaceId
        )
    }
}
