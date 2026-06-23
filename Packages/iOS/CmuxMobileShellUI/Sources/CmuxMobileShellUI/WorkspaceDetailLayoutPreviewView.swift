#if canImport(UIKit) && DEBUG
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// DEBUG-only workspace-detail fixture for simulator layout screenshots.
///
/// Mounted by the root view when `CMUX_UITEST_WORKSPACE_DETAIL_PREVIEW=1`. It
/// renders the production `WorkspaceDetailView` (compact header + terminal grid)
/// inside a pushed navigation stack with a preview store, so the header height
/// and the grid's top edge can be screenshotted without auth or Mac pairing.
struct WorkspaceDetailLayoutPreviewView: View {
    @State private var store = CMUXMobileShellStore.preview()
    @State private var browserStore = BrowserSurfaceStore()

    var body: some View {
        NavigationStack {
            WorkspaceDetailContainer(
                store: store,
                workspaceID: store.selectedWorkspaceID,
                createWorkspace: {},
                safeAreaContext: .fullWidth,
                // Non-nil so the compact header shows the custom back button, and
                // a fixture unread count to exercise the folded "‹ 3" badge.
                onBack: {},
                unreadWorkspaceCount: 3
            )
            .navigationBarBackButtonHidden(true)
        }
        .environment(browserStore)
    }
}
#endif
