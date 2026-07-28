import AppKit

/// Invisible view that reports when its SwiftUI host enters or leaves a window.
final class PopoverAnchorView: NSView {
    var onDidMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
    }
}
