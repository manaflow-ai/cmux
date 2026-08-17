import CmuxAgentChatUI
import CmuxMobileShellModel
import SwiftUI

/// Native iOS renderer for a Mac file-preview panel.
///
/// Routes the panel's displayed file through the shared artifact preview
/// (text with syntax highlighting, image, PDF, media, Quick Look) using the
/// panel-scoped loader; read-only in v1. The embedded preview owns its
/// loading and failure states, so this view only contributes the surface
/// chrome.
struct PanelFileSurfaceView: View {
    let surface: MobileSurfacePreview
    let path: String
    let loader: ChatArtifactLoader
    let connectionStatus: MobileMacConnectionStatus

    var body: some View {
        VStack(spacing: 0) {
            MacSurfaceHeader(
                kind: surface.kind,
                title: surface.title,
                subtitle: MacSurfaceFileContext.subtitle(title: surface.title, path: path)
            )
            ChatArtifactEmbeddedPreview(
                path: path,
                scope: .panel,
                loader: loader,
                refreshToken: surface.title,
                connectionHint: connectionStatus.artifactConnectionHint
            )
        }
    }
}

/// Derives the header subtitle for file-backed surfaces.
enum MacSurfaceFileContext {
    /// The file name when the title doesn't already show it, otherwise the
    /// parent directory name so a duplicated line never appears.
    static func subtitle(title: String, path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty else { return nil }
        if title != fileName { return fileName }
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/" else { return nil }
        return parent
    }
}
