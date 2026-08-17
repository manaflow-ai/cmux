import Foundation

struct WorkspaceTodoPaneItemRowActions {
    let toggleCompletion: () -> Void
    let beginEdit: () -> Void
    let commitEdit: () -> Void
    let cancelEdit: () -> Void
    let focusEditor: () -> Void
    let select: () -> Void
    let markInProgress: () -> Void
    let remove: () -> Void
    let addAttachments: () -> Void
    let removeAttachment: (UUID) -> Void
    let openAttachments: (UUID?) -> Void
    let handleDrop: ([String], Int) -> Bool
}
