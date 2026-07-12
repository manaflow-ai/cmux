import AppKit

/// Bridges an AppKit extension icon button's target-action callback to SwiftUI.
@MainActor
final class CEFExtensionActionButtonCoordinator: NSObject {
    var onActivate: (NSView) -> Void

    init(onActivate: @escaping (NSView) -> Void) {
        self.onActivate = onActivate
    }

    @objc func activate(_ sender: NSButton) {
        onActivate(sender)
    }
}
