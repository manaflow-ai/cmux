import AppKit

/// Geometry and lifetime anchor for the native runaway warning card.
extension RunawayPaneWarningOverlay {
    @MainActor
    final class AnchorView: NSView {
        weak var coordinator: Coordinator?
        override var isHidden: Bool {
            didSet { coordinator?.synchronize() }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { coordinator?.removeCard() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewWillMove(toSuperview newSuperview: NSView?) {
            if newSuperview == nil { coordinator?.removeCard() }
            super.viewWillMove(toSuperview: newSuperview)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.synchronize()
        }
        override func layout() {
            super.layout()
            coordinator?.synchronize()
        }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            coordinator?.synchronize()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            coordinator?.synchronize()
        }
    }
}
