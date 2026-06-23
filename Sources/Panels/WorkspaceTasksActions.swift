import Foundation

struct WorkspaceTasksActions {
    let add: (String, UUID?) -> Bool
    let archive: (UUID) -> Void
    let unarchive: (UUID) -> Void
    let remove: (UUID) -> Void
    let move: (UUID, UUID?, UUID?, Int?) -> Void
    let openSurface: () -> Void
}
