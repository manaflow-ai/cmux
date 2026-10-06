import AppKit
import CmuxNextDesign
import QuartzCore

/// Base class for every row. Rows are passive: the list view owns mouse
/// handling, hover, and drag, so rows return nil from hit testing except for
/// their own buttons.
class SidebarRowView: NSView {
    var key: SidebarRowKey
    var isHovered = false { didSet { if isHovered != oldValue { hoverChanged() } } }

    required init(key: SidebarRowKey) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in interactiveSubviews where !button.isHidden && button.frame.contains(local) {
            return button
        }
        return nil
    }

    /// Fingerprint of the last configured content. Reloads happen on every
    /// drag step, so rows skip work (symbol images, attributed strings,
    /// accessibility) when nothing they show has changed.
    var configuredContent: AnyHashable?

    /// Returns false when `content` matches the last configuration.
    func needsConfigure(_ content: AnyHashable) -> Bool {
        guard content != configuredContent else { return false }
        configuredContent = content
        return true
    }

    /// Resets transient state before a recycled view shows another row.
    func prepareForReuse(key: SidebarRowKey) {
        configuredContent = nil
        self.key = key
        isHovered = false
        // A recycled row shows its new content's fill at once.
        fadesNextFill = false
        layer?.removeAnimation(forKey: "backgroundColor")
        targetSize = nil
        alphaValue = 1
        setTitleHidden(false)
        toolTip = nil
    }

    /// Buttons that receive clicks directly.
    var interactiveSubviews: [NSView] { [] }

    /// Frame of the title text in this row's coordinates, for inline rename.
    var titleFrame: NSRect { .zero }
    var titleFont: NSFont { SidebarStyle.titleFont }
    func setTitleHidden(_ hidden: Bool) {}

    func hoverChanged() {
        fadesNextFill = true
        needsDisplay = true
    }

    /// The next fill change came from hover, so it fades
    /// (`MotionFade.hover`); reloads and theme changes apply at once.
    var fadesNextFill = false

    /// Paints `color` on the row's backing layer, fading when hover changed
    /// it. Call from `updateLayer()` inside the theme scope.
    func paintFill(_ color: NSColor?) {
        guard let layer else { return }
        ChromeHover.paint(layer, color, animated: fadesNextFill)
        fadesNextFill = false
    }

    /// Size the row is animating toward. Content lays out for the final size
    /// up front, so an animated frame change never shows a stale layout.
    var targetSize: NSSize? {
        didSet { if targetSize != oldValue { needsLayout = true } }
    }

    /// Bounds to lay out content in: the target size while animating.
    var layoutBounds: NSRect { NSRect(origin: .zero, size: targetSize ?? bounds.size) }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// A one-line label. Its color is set in the row's `updateLayer`, inside
    /// `performWithTheme`, so it follows the row's theme scope.
    static func label(font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}

// MARK: - Workspace

final class EmptySectionRowView: SidebarRowView {
    private let label = SidebarRowView.label(font: SidebarStyle.subtitleFont)

    required init(key: SidebarRowKey) {
        super.init(key: key)
        // Left-aligned where a workspace's title would start, so the empty
        // list reads as the list's first line, not a caption floating in
        // the middle of an empty column.
        label.alignment = .natural
        addSubview(label)
    }

    func configure(pinned: Bool) {
        label.stringValue = pinned ? Strings.pinnedEmpty : Strings.sectionEmpty
        label.font = SidebarStyle.subtitleFont
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(label.intrinsicContentSize.height)
        let x = SidebarStyle.titleLeading
        label.frame = NSRect(x: x, y: (b.height - h) / 2, width: max(0, b.width - x - Metrics.space2), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme { label.textColor = Palette.textTertiary }
    }
}
