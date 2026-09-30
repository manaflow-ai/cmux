import AppKit
import SwiftUI

struct FilePreviewImageView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewImageContainerView {
        panel.nativeViewSessions.image.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: FilePreviewImageContainerView, context: Context) {
        panel.nativeViewSessions.image.update(
            nsView,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}
