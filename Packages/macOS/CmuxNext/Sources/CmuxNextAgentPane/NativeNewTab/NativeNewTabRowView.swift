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
        for label in [title, detail, hint] {
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
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
        title.font = Typography.body
        detail.font = Typography.caption
        hint.font = Typography.shortcut
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
        let hintWidth = hint.isHidden ? 0 : ceil(hint.intrinsicContentSize.width)
        hint.frame = centered(x: trailing - hintWidth, width: hintWidth, label: hint)
        let limit = hint.isHidden ? trailing : trailing - hintWidth - gap
        let titleWidth = min(ceil(title.intrinsicContentSize.width), max(0, limit - x))
        title.frame = centered(x: x, width: titleWidth, label: title)
        x += titleWidth + gap
        detail.frame = centered(x: x, width: max(0, min(ceil(detail.intrinsicContentSize.width), limit - x)), label: detail)
    }

    private func centered(x: CGFloat, width: CGFloat, label: NSTextField) -> NSRect {
        let height = ceil(label.intrinsicContentSize.height)
        return NSRect(x: x, y: floor((bounds.height - height) / 2), width: width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
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
