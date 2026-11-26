import AppKit
import CmuxFoundation

/// Native search control shared by Find and Vault.
@MainActor
class SidebarSearchField: NSSearchField {
    /// Bezel inset from the sidebar edge: the same leading column as the
    /// right-sidebar chrome bars, which the icon alignment below compensates.
    static let leadingPadding: CGFloat = RightSidebarChromeMetrics.headerLeadingPadding
    static let topPadding: CGFloat = 0

    var onCommandSubmit: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override class var cellClass: AnyClass? {
        get { SidebarSearchFieldCell.self }
        set { super.cellClass = newValue }
    }

    static var visibleHeight: CGFloat {
        max(22, RightSidebarChromeMetrics.controlHeight + 2)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func applyFontScale() {
        font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .regular)
    }

    override var searchButtonBounds: NSRect {
        Self.alignedSearchButtonRect(super.searchButtonBounds, in: bounds)
    }

    override var searchTextBounds: NSRect {
        Self.alignedSearchTextRect(super.searchTextBounds, in: bounds)
    }

    static func alignedSearchButtonRect(_ nativeRect: NSRect, in bounds: NSRect) -> NSRect {
        var rect = nativeRect
        rect.size.width = RightSidebarChromeMetrics.contentIconFrameSize
        rect.origin.x = bounds.minX + RightSidebarChromeMetrics.contentIconCenter - leadingPadding - rect.width / 2
        return rect
    }

    static func alignedSearchTextRect(_ nativeRect: NSRect, in bounds: NSRect) -> NSRect {
        var rect = nativeRect
        // Native text drawing and the field editor both add this inner inset.
        let leading = bounds.minX + RightSidebarChromeMetrics.contentTextLeadingPadding - leadingPadding - 2
        rect.origin.x = min(leading, nativeRect.maxX)
        rect.size.width = max(0, nativeRect.maxX - rect.minX)
        return rect
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled, isEditable else { return }
        addCursorRect(searchTextBounds, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { updateHoverCursor(with: event) }
    override func mouseEntered(with event: NSEvent) { updateHoverCursor(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHoverCursor(with: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    private func updateHoverCursor(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cursor: NSCursor = isEnabled && isEditable && searchTextBounds.contains(point) ? .iBeam : .arrow
        cursor.set()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCommandSubmit(event) || super.performKeyEquivalent(with: event)
    }

    func handleCommandSubmit(_ event: NSEvent) -> Bool {
        guard let onCommandSubmit,
              let editor = currentEditor() as? NSTextView,
              window?.firstResponder === editor,
              !editor.hasMarkedText(),
              event.type == .keyDown,
              event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.contains(.command) else { return false }
        onCommandSubmit()
        return true
    }

    private func configure() {
        focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyFontScale()
    }
}
