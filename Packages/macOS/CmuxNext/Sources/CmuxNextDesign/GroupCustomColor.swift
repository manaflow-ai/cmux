public import AppKit
import QuartzCore
import CmuxNextCompat

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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
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

/// The app's one borrower of the system color panel (`NSColorPanel.shared`, one per app). Every part
/// that picks a color with it (a group editor's custom color, cx-25az; a chat's Chat Colors) borrows it
/// here, so only the latest borrower receives colors: a new borrow ends the previous one, which hears
/// it through its `onEnd`. The panel's own settings are kept from before the first borrow and put back
/// when the last borrower is done or the person closes the panel.
@MainActor
public final class GroupColorPanel: NSObject {
    public static let shared = GroupColorPanel()

    /// A borrow's token: `giveBack` and `holds` name the borrow they mean.
    public struct Borrow: Equatable, Sendable {
        let id: UInt64
    }

    private var onPick: ((NSColor) -> Void)?
    private var onEnd: (() -> Void)?
    private var current: Borrow?
    private var nextID: UInt64 = 0
    /// The shared panel's settings before it was borrowed, put back when it is given back.
    private var borrowed: (showsAlpha: Bool, isContinuous: Bool)?
    private var closeObserver: MainActorObservation?

    override public init() {
        super.init()
    }

    /// A group editor's custom color: each color the person settles on goes out once (not while
    /// dragging). A group editor bubble closes when the panel takes focus, so this keeps where the
    /// color goes after the editor that opened it is gone.
    public func open(current: GroupTint?, onColor: @escaping (GroupTint) -> Void) {
        borrow(start: current?.picked, continuous: false, onPick: { color in
            if let tint = GroupTint(picked: color) { onColor(tint) }
        }, onEnd: {})
        NSColorPanel.shared.makeKeyAndOrderFront(nil)
    }

    /// Borrows the panel: `onPick` receives each color from now on (every change when `continuous`,
    /// else the settled one), until the next borrow, `giveBack`, or the person closes the panel; then
    /// `onEnd` runs once (not when the borrower gives it back itself). Setting `start` is not a pick.
    /// The caller shows the panel where it wants it.
    @discardableResult
    public func borrow(start: NSColor?, continuous: Bool, onPick: @escaping (NSColor) -> Void,
                       onEnd: @escaping () -> Void) -> Borrow {
        let previousEnd = self.onEnd
        let panel = NSColorPanel.shared
        if borrowed == nil {
            borrowed = (panel.showsAlpha, panel.isContinuous)
        }
        if closeObserver == nil {
            // The panel is shared: once it closes, its colors no longer go to anyone.
            closeObserver = MainActorObservation(NSWindow.willCloseNotification, object: panel) { [weak self] in
                self?.end(notify: true)
            }
        }
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = continuous
        if let start { panel.color = start }
        nextID += 1
        let borrow = Borrow(id: nextID)
        (current, self.onPick, self.onEnd) = (borrow, onPick, onEnd)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        previousEnd?()
        return borrow
    }

    /// Gives the panel back, when `borrow` still has it (a later borrow already took it otherwise).
    public func giveBack(_ borrow: Borrow) {
        guard current == borrow else { return }
        end(notify: false)
    }

    /// Whether `borrow` still has the panel.
    public func holds(_ borrow: Borrow) -> Bool { current == borrow }

    private func end(notify: Bool) {
        let panel = NSColorPanel.shared
        let ended = onEnd
        if current != nil {
            panel.setTarget(nil)
            panel.setAction(nil)
        }
        if let borrowed {
            panel.showsAlpha = borrowed.showsAlpha
            panel.isContinuous = borrowed.isContinuous
        }
        (borrowed, current, onPick, onEnd, closeObserver) = (nil, nil, nil, nil, nil)
        if notify { ended?() }
    }

    @objc private func changed(_ sender: Any?) {
        onPick?(NSColorPanel.shared.color)
    }
}
