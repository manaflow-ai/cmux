import AppKit

/// Routes the AppKit share button action back to its SwiftUI owner.
@MainActor
final class FilePreviewPDFShareButtonCoordinator: NSObject {
    var action: (NSView) -> Void

    init(action: @escaping (NSView) -> Void) {
        self.action = action
    }

    @objc func share(_ sender: NSButton) {
        action(sender)
    }
}
