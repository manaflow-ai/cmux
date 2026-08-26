import AppKit

/// Routes the AppKit share button action back to its SwiftUI owner.
@MainActor
final class FilePreviewPDFShareButtonCoordinator: NSObject {
    var action: (NSView, FilePreviewPDFShareActivation) -> Void

    init(action: @escaping (NSView, FilePreviewPDFShareActivation) -> Void) {
        self.action = action
    }

    @objc func share(_ sender: FilePreviewPDFShareButtonControl) {
        action(sender, sender.shareActivation)
    }
}
