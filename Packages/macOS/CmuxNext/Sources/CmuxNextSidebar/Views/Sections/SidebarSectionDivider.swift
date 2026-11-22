import AppKit
import CmuxNextDesign

/// The drag handle on the top edge of a stacked sidebar section with a list (All chats,
/// Lawrence 2026-10-09): drag to resize, double-click to reset, a resize cursor on hover, and
/// an adjustable splitter for VoiceOver (increment/decrement by one row).
final class SidebarSectionDivider: NSView {
    /// The drag moved `delta` points from the press (positive: down).
    var onDrag: ((CGFloat) -> Void)?
    var onDragStart: (() -> Void)?
    var onReset: (() -> Void)?
    /// VoiceOver: `+1` grows the section by a row, `-1` shrinks it.
    var onStep: ((Int) -> Void)?
    /// VoiceOver reads this (the section's share of the sidebar, as a percentage).
    var valueDescription: (() -> String?)?
    private var pressY: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(SidebarChatsView.resizeLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pressY = nil; onReset?(); return }
        pressY = event.locationInWindow.y
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressY else { return }
        // Window coordinates grow upward: dragging down is a positive delta here.
        onDrag?(pressY - event.locationInWindow.y)
    }

    override func mouseUp(with event: NSEvent) { pressY = nil }

    override func accessibilityValue() -> Any? { valueDescription?() }
    override func accessibilityPerformIncrement() -> Bool { onStep?(1); return true }
    override func accessibilityPerformDecrement() -> Bool { onStep?(-1); return true }
}
