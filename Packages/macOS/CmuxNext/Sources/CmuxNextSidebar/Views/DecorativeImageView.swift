import AppKit

/// An image that only decorates text beside it, so accessibility clients skip it: an unlabeled
/// `AXImage` is noise to VoiceOver and to computer-use agents that read the tree.
///
/// An image view answers accessibility through its cell, so `setAccessibilityElement(false)` on
/// the view alone still exposes the image; this type hides both.
class DecorativeImageView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell?.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func isAccessibilityElement() -> Bool { false }
}
