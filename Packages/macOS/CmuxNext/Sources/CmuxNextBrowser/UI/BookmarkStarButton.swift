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
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = OmnibarStyle.chipCornerRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleNone
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ProfileBadgeView.size + 4),
            heightAnchor.constraint(equalToConstant: ProfileBadgeView.size + 4),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(self)
    }

    override func viewDidHide() {
        super.viewDidHide()
        hover?.refresh()
    }

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
