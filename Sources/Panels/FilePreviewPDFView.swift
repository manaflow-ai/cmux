import AppKit
import SwiftUI

struct FilePreviewPDFView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewPDFContainerView {
        panel.nativeViewSessions.pdf.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: FilePreviewPDFContainerView, context: Context) {
        panel.nativeViewSessions.pdf.update(
            nsView,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}
