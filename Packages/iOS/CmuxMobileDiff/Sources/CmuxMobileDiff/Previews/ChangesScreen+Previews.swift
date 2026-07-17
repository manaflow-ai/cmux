internal import SwiftUI

#Preview("Native changes") {
    NavigationStack {
        ChangesScreen(
            service: PreviewChangesService(),
            workspace: ChangesWorkspaceContext(workspaceID: "preview-workspace", displayName: "cmux")
        )
    }
}
