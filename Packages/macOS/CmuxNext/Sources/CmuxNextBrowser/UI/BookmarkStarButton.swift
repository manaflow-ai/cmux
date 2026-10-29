public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// Whether the omnibar shows the bookmark star, and filled or hollow
/// (plans/cmux-next/bookmarks.md section 3).
public enum BookmarkStarState: Hashable, Sendable {
    /// No star: a page that cannot be bookmarked (blank, internal) or no host wiring.
    case hidden
    /// Hollow: the page is not bookmarked.
    case off
    /// Filled: the page is bookmarked in this tab's browser profile.
    case on
}

/// The star at the trailing end of the omnibar. Click (or Space/Return when
/// it has the keyboard) asks the host to bookmark the page or edit its
/// bookmark; the host anchors the edit bubble at this view.
final class BookmarkStarButton: NSView, PointerHoverReporting {
    private let image = NSImageView()
    /// Where the pointer is now (`OmnibarPointer`).
    private var hover: PointerHover?
    private var isHovered: Bool { hover?.isHovering ?? false }
    var isPointerHovering: Bool { isHovered }
    var onPress: ((NSView) -> Void)?

    var state: BookmarkStarState = .hidden {
        didSet {
            guard state != oldValue else { return }
            image.image = NSImage.icon(state == .on ? .browserOmniboxStarActive : .browserOmniboxStar, size: OmnibarStyle.trailingIconSize)
            let label = state == .on ? Strings.bookmarkEdit : Strings.bookmarkAdd
            setAccessibilityLabel(label)
            needsDisplay = true
            needsLayout = true // invalidate: another state (the guard above) centers another glyph
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = OmnibarStyle.chipCornerRadius
        layer?.cornerCurve = .continuous
        image.imageScaling = .scaleNone
        addSubview(image)
        // The omnibar's badge row keeps the star at its size, as a fixed one.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.required, for: orientation)
            setContentCompressionResistancePriority(.required, for: orientation)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("cmux.browser.bookmarkStar")
        hover = PointerHover(self) { [weak self] _ in self?.paintFill(animated: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The badge takes the whole press (not its image or label) and the first
    /// one in a browser window that is not key: one click acts, as Chrome's
    /// omnibar buttons do (user, 2026-10-28, "click the star twice").
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Frame layout

    /// The square the star sits in: a profile badge's size and 2 pt around it.
    static let side = ProfileBadgeView.size + 4

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        if newSize != oldSize { needsLayout = true } // invalidate: a new size (the check above) centers the star again
    }

    /// The star centered in the square at its own size.
    override func layout() {
        super.layout()
        image.setAlignmentFrame(ProfileBadgeView.centered(image.intrinsicContentSize, in: bounds))
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(self)
    }

    // visibility-walk-allow: hover is a hit test: a view hidden or shown under a still pointer gets no exit or enter, so PointerHover reads the pointer again (input state, no view work)
    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

    // visibility-walk-allow: hover is a hit test: a view hidden or shown under a still pointer gets no exit or enter, so PointerHover reads the pointer again (input state, no view work)
    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover?.refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hover?.refresh()
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // A redraw during a hover fade leaves the fade running.
        if layer?.animation(forKey: "backgroundColor") == nil { paintFill(animated: false) }
        performWithTheme {
            image.contentTintColor = state == .on ? OmnibarStyle.textPrimary : OmnibarStyle.textSecondary
        }
    }

    /// The hover fill eases in and clears at once (`ChromeHover.fade`).
    private func paintFill(animated: Bool) {
        guard let layer else { return }
        performWithTheme {
            ChromeHover.paint(layer, isHovered ? OmnibarStyle.chipHoverFill : nil, animated: animated && window != nil)
        }
    }
}
