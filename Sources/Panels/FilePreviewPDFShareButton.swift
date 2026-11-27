import AppKit
import SwiftUI

/// AppKit-backed PDF share control that dispatches while handling mouse-down.
struct FilePreviewPDFShareButton: NSViewRepresentable {
    let label: String
    let action: (NSView, FilePreviewPDFShareActivation) -> Void

    func makeCoordinator() -> FilePreviewPDFShareButtonCoordinator {
        FilePreviewPDFShareButtonCoordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = FilePreviewPDFShareButtonControl()
        button.identifier = NSUserInterfaceItemIdentifier("FilePreviewPDFShareButton")
        button.title = ""
        button.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: label
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(FilePreviewPDFShareButtonCoordinator.share(_:))
        // NSSharingServicePicker.show must run during the originating mouse-down.
        _ = button.sendAction(on: .leftMouseDown)
        update(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        update(button)
    }

    private func update(_ button: NSButton) {
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.image?.accessibilityDescription = label
    }
}
