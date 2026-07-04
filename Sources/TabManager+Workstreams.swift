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
        workstreamCoordinator.enterWorkstream(id: id)
    }

    /// Return to the top-level workstream list.
    func exitWorkstreamDrillIn() {
        workstreamCoordinator.exitWorkstreamDrillIn()
    }
}
