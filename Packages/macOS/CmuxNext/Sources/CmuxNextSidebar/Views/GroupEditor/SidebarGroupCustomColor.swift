import AppKit
import CmuxNextDesign
import QuartzCore

/// The custom color dot after the palette (cx-25az): icon-only, it opens
/// the system color panel (wheel, sliders and a hex field). Once a group has
/// a custom color the dot shows it, with the chosen ring.
final class SidebarGroupCustomSwatchView: NSView {
    var isChosen = false { didSet { if oldValue != isChosen { updateColors() } } }
    /// The group's custom color; nil draws the eyedropper.
    var custom: GroupTint? { didSet { if oldValue != custom { updateColors() } } }
    var onPress: (() -> Void)?
    private let fill = CALayer()
    private let ring = CALayer()
    private let glyph = NSImageView()
    private var isHovered = false { didSet { if oldValue != isHovered { updateColors() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
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
        setAccessibilityLabel(GroupEditorStrings.customColor)
        toolTip = GroupEditorStrings.customColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let side = Metrics.iconSize + Metrics.space2
        return NSSize(width: side, height: side)
    }

    override func layout() {
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

    override func viewDidChangeEffectiveAppearance() {
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

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The system color panel for one group's custom color (cx-25az). The
/// editor bubble closes when the panel takes focus, so the group is kept
/// here; each color the person settles on goes out once (not while dragging).
@MainActor
final class SidebarGroupColorPanel: NSObject {
    private var group: GroupID?
    var onColor: ((GroupID, GroupTint) -> Void)?

    /// The shared panel's settings before it was borrowed, put back when it closes.
    private var borrowed: (showsAlpha: Bool, isContinuous: Bool)?
    private var closeObserver: NSObjectProtocol?

    func open(for group: GroupID, current: GroupTint?) {
        self.group = group
        let panel = NSColorPanel.shared
        if borrowed == nil { borrowed = (panel.showsAlpha, panel.isContinuous) }
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        if let picked = current?.picked { panel.color = picked }
        // The panel is shared: once it closes, its colors no longer go to this group.
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.release() } // main-proof: queue: .main delivers on the main thread
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func release() {
        let panel = NSColorPanel.shared
        if group != nil {
            panel.setTarget(nil)
            panel.setAction(nil)
        }
        if let borrowed {
            panel.showsAlpha = borrowed.showsAlpha
            panel.isContinuous = borrowed.isContinuous
        }
        borrowed = nil
        group = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    @objc private func changed(_ sender: Any?) {
        guard let group, let tint = GroupTint(picked: NSColorPanel.shared.color) else { return }
        onColor?(group, tint)
    }
}
