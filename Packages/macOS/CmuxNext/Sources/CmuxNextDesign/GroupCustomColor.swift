public import AppKit
import QuartzCore
import CmuxNextCompat
import CmuxNextWakeups
public import CmuxNextDesignTokens

/// The custom color dot after a group editor's palette dots (cx-25az, tab groups cx-wqn5):
/// icon-only, it opens the system color panel (wheel, sliders and a hex field). Once a group has
/// a custom color the dot shows it, with the chosen ring.
public final class GroupCustomSwatchView: NSView {
    public var isChosen = false { didSet { if oldValue != isChosen { updateColors() } } }
    /// The group's custom color; nil draws the eyedropper.
    public var custom: GroupTint? { didSet { if oldValue != custom { updateColors() } } }
    public var onPress: (() -> Void)?
    private let fill = CALayer()
    private let ring = CALayer()
    private let glyph = NSImageView()
    private var isHovered = false { didSet { if oldValue != isHovered { updateColors() } } }

    /// `label` names the dot for VoiceOver and its tooltip, from the editor's own catalog.
    public init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        ring.borderWidth = Metrics.space1 * 0.75
        for sublayer in [ring, fill] {
            sublayer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull()]
            layer?.addSublayer(sublayer)
        }
        glyph.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Metrics.smallIconSize - Metrics.space1, weight: .semibold)
        addSubview(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(label)
        themedToolTip = label
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeForHover, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var intrinsicContentSize: NSSize {
        let side = Metrics.iconSize + Metrics.space2
        return NSSize(width: side, height: side)
    }

    override public func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let outer = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        ring.frame = outer
        ring.cornerRadius = side / 2
        let inner = outer.insetBy(dx: Metrics.space1 + 1, dy: Metrics.space1 + 1)
        fill.frame = inner
        fill.cornerRadius = inner.width / 2
        glyph.frame = inner
        updateColors()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            fill.backgroundColor = custom?.headerFill.cgColor
            fill.borderColor = Palette.textTertiary.cgColor
            fill.borderWidth = custom == nil ? Metrics.dividerThickness : 0
            glyph.isHidden = custom != nil
            glyph.contentTintColor = Palette.textSecondary
            ring.borderColor = (isChosen ? Palette.textPrimary : (isHovered ? Palette.separator : NSColor.clear)).cgColor
        }
        setAccessibilityValue(isChosen ? 1 : 0)
    }

    override public func mouseEntered(with event: NSEvent) { isHovered = true }
    override public func mouseExited(with event: NSEvent) { isHovered = false }
    override public func mouseDown(with event: NSEvent) {}
    override public func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override public func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The system color panel for a group's custom color (cx-25az). A group editor bubble closes
/// when the panel takes focus, so `open` keeps where the color goes (its `onColor`); each color
/// the person settles on goes out once (not while dragging). One for the app, like the panel it
/// borrows: it stays the panel's target after any editor that opened it is gone.
@MainActor
public final class GroupColorPanel: NSObject {
    public static let shared = GroupColorPanel()

    private var onColor: ((GroupTint) -> Void)?
    /// The shared panel's settings before it was borrowed, put back when it closes.
    private var borrowed: (showsAlpha: Bool, isContinuous: Bool)?
    /// The shared panel's close, through its window's ``WindowEvents`` (one observer per notice for the panel).
    private var closeObserver: EventSubscription?

    override public init() {
        super.init()
    }

    public func open(current: GroupTint?, onColor: @escaping (GroupTint) -> Void) {
        self.onColor = onColor
        let panel = NSColorPanel.shared
        if borrowed == nil {
            borrowed = (panel.showsAlpha, panel.isContinuous)
        }
        // The panel is shared: once it closes, its colors no longer go to this group.
        if closeObserver == nil {
            closeObserver = WindowEvents.of(panel).subscribe(NSWindow.willCloseNotification, owner: "GroupColorPanel") { [weak self] in
                self?.release()
            }
        }
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        if let picked = current?.picked { panel.color = picked }
        panel.makeKeyAndOrderFront(nil)
    }

    private func release() {
        let panel = NSColorPanel.shared
        if onColor != nil {
            panel.setTarget(nil)
            panel.setAction(nil)
        }
        if let borrowed {
            panel.showsAlpha = borrowed.showsAlpha
            panel.isContinuous = borrowed.isContinuous
        }
        borrowed = nil
        onColor = nil
        closeObserver = nil
    }

    @objc private func changed(_ sender: Any?) {
        guard let onColor, let tint = GroupTint(picked: NSColorPanel.shared.color) else { return }
        onColor(tint)
    }
}
