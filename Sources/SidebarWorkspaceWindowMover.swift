import Foundation

/// Moves an ordered workspace selection between app windows exactly once per workspace.
@MainActor
struct SidebarWorkspaceWindowMover {
    private let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
    }

    func moveWorkspaces(_ orderedWorkspaceIds: [UUID], toWindow windowId: UUID) -> [UUID] {
        var movedIds: [UUID] = []
        movedIds.reserveCapacity(orderedWorkspaceIds.count)

        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            if app.moveWorkspaceToWindow(
                workspaceId: workspaceId,
                windowId: windowId,
                focus: shouldFocus
            ) {
                movedIds.append(workspaceId)
            }
        }

        return movedIds
    }

    func moveWorkspacesToNewWindow(_ orderedWorkspaceIds: [UUID]) -> [UUID] {
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return [] }

        if orderedWorkspaceIds.count == 1 {
            guard app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: true) != nil else {
                return []
            }
            return [firstWorkspaceId]
        }

        guard let newWindowId = app.moveWorkspaceToNewWindow(
            workspaceId: firstWorkspaceId,
            focus: false
        ) else {
            return []
        }

        var movedIds = [firstWorkspaceId]
        movedIds.reserveCapacity(orderedWorkspaceIds.count)

        for workspaceId in orderedWorkspaceIds.dropFirst().dropLast() {
            if app.moveWorkspaceToWindow(
                workspaceId: workspaceId,
                windowId: newWindowId,
                focus: false
            ) {
                movedIds.append(workspaceId)
            }
        }

        if let finalWorkspaceId = orderedWorkspaceIds.last,
           app.moveWorkspaceToWindow(
               workspaceId: finalWorkspaceId,
               windowId: newWindowId,
               focus: true
           ) {
            movedIds.append(finalWorkspaceId)
        }

        return movedIds
    }
}
