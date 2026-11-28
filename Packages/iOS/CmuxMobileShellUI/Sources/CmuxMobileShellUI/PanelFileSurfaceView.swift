import CmuxAgentChatUI
import CmuxMobileShellModel
import SwiftUI

/// Native iOS renderer for a Mac file-preview panel.
///
/// Routes the panel's displayed file through the shared artifact preview
/// (text with syntax highlighting, image, PDF, media, Quick Look) using the
/// panel-scoped loader; read-only in v1. The embedded preview owns its
/// loading and failure states; the navigation bar already names the surface,
/// so the pane renders content edge to edge with no extra chrome.
struct PanelFileSurfaceView: View {
    let surface: MobileSurfacePreview
    let path: String
    let loader: ChatArtifactLoader
    let connectionStatus: MobileMacConnectionStatus

    var body: some View {
        ChatArtifactEmbeddedPreview(
            path: path,
            scope: .panel,
            loader: loader,
            refreshToken: surface.title,
            connectionHint: connectionStatus.artifactConnectionHint
        )
    }
}
