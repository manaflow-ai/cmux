import Foundation

extension AppDelegate {
    func publishRemoteRuntimeStateSnapshots(_ snapshot: AppSessionSnapshot) {
        let liveWorkspaces = sortedMainWindowContextsForSessionSnapshot()
            .flatMap(\.tabManager.tabs)
        let liveByID = Dictionary(uniqueKeysWithValues: liveWorkspaces.map { ($0.id, $0) })
        for workspaceSnapshot in snapshot.windows.flatMap(\.tabManager.workspaces) {
            guard let workspaceID = workspaceSnapshot.workspaceId,
                  let workspace = liveByID[workspaceID] else { continue }
            workspace.enqueueRemoteRuntimeState(workspaceSnapshot)
        }
    }
}
