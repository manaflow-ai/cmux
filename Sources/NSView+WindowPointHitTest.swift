import AppKit

extension NSView {
    /// Hit-tests a window-space point through this view the way AppKit does.
    ///
    /// `NSView.hitTest(_:)` takes a point in the receiver's *superview*
    /// coordinate space. The main window's content view is a flipped SwiftUI
    /// host while the window's frame view is not, so a point converted into
    /// the content view itself and handed to `hitTest` is mirrored vertically:
    /// a press near the top of the window is answered by whatever sits near
    /// the bottom (cmux issue 12152, where the file editor answered for the
    /// pane tab strip). Every window-space hit-test in the app goes through
    /// this helper so the coordinate space is decided once.
    func cmuxHitTest(windowPoint: NSPoint) -> NSView? {
        let reference = superview ?? self
        return hitTest(reference.convert(windowPoint, from: nil))
    }
}
