import AppKit
import CmuxNextDesign

/// One dropdown row: a value snapshot and a closure (no model reference below the list).
///
/// The symbol, the title, the detail (middle-truncated) and the trailing hint; the selected row
/// has an accent tint. A click runs ``activate``.
final class NativeNewTabRowView: NSView {
    /// The row's height.
    static let height: CGFloat = 30

    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private(set) var content: NativeNewTabRowContent?
    /// The title label (tests read its frame).
    var titleField: NSTextField { title }
    /// The detail label (tests read its frame).
    var detailField: NSTextField { detail }
    private(set) var selected = false
    /// Runs the row, as a click on it does.
    var activate: @MainActor () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        symbol.contentTintColor = .secondaryLabelColor
        symbol.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        detail.textColor = .secondaryLabelColor
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        // One line, never wrapping: a wrapping cell (maximumNumberOfLines) measures its intrinsic
        // width against its current frame, so a row's first layout gave each label a few points.
        for label in [title, detail, hint] {
            label.usesSingleLineMode = true
            label.cell?.wraps = false
            label.cell?.isScrollable = false
        }
        for view in [symbol, title, detail, hint] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `content`, tinted when `selected`.
    func show(_ content: NativeNewTabRowContent, selected: Bool) {
        if content != self.content {
            self.content = content
            symbol.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)
            title.stringValue = content.title
            detail.stringValue = content.detail ?? ""
            detail.isHidden = content.detail == nil
            hint.stringValue = content.hint ?? ""
            hint.isHidden = content.hint == nil
            setAccessibilityLabel(content.title)
            needsLayout = true
        }
        // Fonts follow the density and text size, read at each show.
        let fonts = (Typography.body, Typography.caption, Typography.shortcut)
        if title.font != fonts.0 || detail.font != fonts.1 || hint.font != fonts.2 {
            (title.font, detail.font, hint.font) = (fonts.0, fonts.1, fonts.2)
            needsLayout = true
        }
        self.selected = selected
        updateTint()
    }

    private func updateTint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? Palette.accent.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    override func layout() {
        super.layout()
        let inset = Metrics.space4
        let gap = Metrics.space3
        var x = inset
        symbol.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 18, height: 16)
        x += 18 + gap
        let trailing = bounds.width - inset
        let hintWidth = hint.isHidden ? 0 : textWidth(hint)
        hint.frame = centered(x: trailing - hintWidth, width: hintWidth, label: hint)
        let limit = hint.isHidden ? trailing : trailing - hintWidth - gap
        let titleWidth = min(textWidth(title), max(0, limit - x))
        title.frame = centered(x: x, width: titleWidth, label: title)
        x += titleWidth + gap
        // The detail sits on the title's baseline (its font is smaller, so centering it drops it low).
        var detailFrame = centered(x: x, width: max(0, min(textWidth(detail), limit - x)), label: detail)
        detailFrame.origin.y = title.frame.maxY - title.firstBaselineOffsetFromTop
            - (detailFrame.height - detail.firstBaselineOffsetFromTop)
        detail.frame = detailFrame
    }

    /// The label's text on one line, measured from the text (not from the label's current frame).
    private func textWidth(_ label: NSTextField) -> CGFloat {
        let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return ceil(label.cell?.cellSize(forBounds: unbounded).width ?? label.attributedStringValue.size().width)
    }

    private func centered(x: CGFloat, width: CGFloat, label: NSTextField) -> NSRect {
        let height = ceil(label.intrinsicContentSize.height)
        return NSRect(x: x, y: floor((bounds.height - height) / 2), width: width, height: height)
    }

    /// A row the list no longer shows takes no click (AppKit's own `hitTest` skips hidden views).
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    /// A new width moves the hint and truncates the title again.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }
}
