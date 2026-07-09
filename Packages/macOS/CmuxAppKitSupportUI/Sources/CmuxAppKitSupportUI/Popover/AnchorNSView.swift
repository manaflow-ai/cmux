import AppKit

/// An empty `NSView` that invokes `onLayout` after each `layout()` pass, used to surface a
/// laid-out anchor view back to SwiftUI once its window-space frame is settled.
final class AnchorNSView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}
