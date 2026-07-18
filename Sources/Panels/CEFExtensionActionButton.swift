import AppKit
import SwiftUI

/// Renders one extension action as a template-style AppKit toolbar button.
struct CEFExtensionActionButton: NSViewRepresentable {
    let action: CEFExtensionAction
    let onActivate: (NSView) -> Void

    func makeCoordinator() -> CEFExtensionActionButtonCoordinator {
        CEFExtensionActionButtonCoordinator(onActivate: onActivate)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: resolvedImage,
            target: context.coordinator,
            action: #selector(CEFExtensionActionButtonCoordinator.activate(_:))
        )
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onActivate = onActivate
        update(nsView, coordinator: context.coordinator)
    }

    private var resolvedImage: NSImage {
        if let icon = action.icon { return icon }
        return NSImage(
            systemSymbolName: "puzzlepiece.extension",
            accessibilityDescription: nil
        ) ?? NSImage()
    }

    private func update(
        _ button: NSButton,
        coordinator: CEFExtensionActionButtonCoordinator
    ) {
        _ = coordinator
        button.image = resolvedImage
        button.toolTip = action.name
        button.setAccessibilityLabel(
            String(
                format: String(
                    localized: "cef.extension.open.accessibilityLabel.format",
                    defaultValue: "Open %@ extension"
                ),
                action.name
            )
        )
    }
}
