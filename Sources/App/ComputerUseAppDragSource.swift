import AppKit
import SwiftUI

/// Hosts the native file drag source used by the Computer Use onboarding card.
@MainActor
struct ComputerUseAppDragSource: NSViewRepresentable {
    let helperAppURL: URL?
    let helperIcon: NSImage?
    let onDragEnded: (NSDragOperation) -> Void

    func makeNSView(context: Context) -> ComputerUseAppDragSourceView {
        let view = ComputerUseAppDragSourceView()
        view.setAccessibilityIdentifier("ComputerUseHelperAppDragSource")
        return view
    }

    func updateNSView(_ nsView: ComputerUseAppDragSourceView, context: Context) {
        nsView.update(
            helperAppURL: helperAppURL,
            helperIcon: helperIcon,
            onDragEnded: onDragEnded
        )
    }
}
