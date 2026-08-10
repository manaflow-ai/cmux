import Foundation

struct GlobalSearchTitleSnapshot: Equatable {
    let windowID: UUID
    let windowTitle: String
    let workspaceID: UUID
    let workspaceTitle: String
    let panelTitle: String

    init(context: GlobalSearchPanelContext) {
        windowID = context.windowID
        windowTitle = context.windowTitle
        workspaceID = context.workspaceID
        workspaceTitle = context.workspaceTitle
        panelTitle = context.panelTitle
    }
}
