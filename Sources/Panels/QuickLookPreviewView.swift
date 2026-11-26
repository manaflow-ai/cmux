import AppKit
import SwiftUI

struct QuickLookPreviewView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let revision: Int
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeCoordinator() -> FilePreviewQuickLookViewCoordinator {
        FilePreviewQuickLookViewCoordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSView {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        return quickLook.view(
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        quickLook.update(
            nsView,
            panel: panel,
            revision: revision,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: FilePreviewQuickLookViewCoordinator) {
        coordinator.quickLook?.dismantle(nsView)
        coordinator.quickLook = nil
    }
}
