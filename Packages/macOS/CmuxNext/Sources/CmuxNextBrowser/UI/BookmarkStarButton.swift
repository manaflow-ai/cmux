public import AppKit
import CmuxNextDesign

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
final class BookmarkStarButton: NSView {
    private let image = NSImageView()
    private var isHovered = false
    private var tracking: NSTrackingArea?
    var onPress: ((NSView) -> Void)?

    var state: BookmarkStarState = .hidden {
        didSet {
            guard state != oldValue else { return }
            image.image = NSImage(systemSymbolName: state == .on ? "star.fill" : "star", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: OmnibarStyle.iconPointSize, weight: .regular))
            let label = state == .on ? Strings.bookmarkEdit : Strings.bookmarkAdd
            toolTip = label
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            layer?.backgroundColor = isHovered ? OmnibarStyle.chipHoverFill.cgColor : NSColor.clear.cgColor
            image.contentTintColor = state == .on ? OmnibarStyle.textPrimary : OmnibarStyle.textSecondary
        }
    }
}
