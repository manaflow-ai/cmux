import AppKit
import CmuxNextDesign

/// Allow and Deny for a sidebar row whose chat's one pending tool permission the App can answer (the
/// Needs You tray, a Priority row; cmuxterm-hq#7794): Allow on a quiet resting fill, Deny quieter
/// still, each with the key that presses it while the row has the focus (Y, N; ``SidebarAnswerKey``),
/// as the agent pane's permission card shows its keys. The App answers; the row only asks.
final class SidebarAnswerButtons: NSView {
    /// Allow (true) or Deny (false) pressed.
    var onAnswer: ((Bool) -> Void)?
    let allow = SidebarAnswerButton(title: Strings.answerAllow, key: "Y", label: Strings.answerAllowLabel, prominent: true)
    let deny = SidebarAnswerButton(title: Strings.answerDeny, key: "N", label: Strings.answerDenyLabel, prominent: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for button in [allow, deny] { addSubview(button) }
        allow.onPress = { [weak self] in self?.onAnswer?(true) }
        deny.onPress = { [weak self] in self?.onAnswer?(false) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// The width both buttons take, side by side with a small gap: Deny first, Allow at the trailing edge.
    var naturalWidth: CGFloat { ceil(allow.naturalSize.width) + Metrics.space1 + ceil(deny.naturalSize.width) }
    var naturalHeight: CGFloat { max(allow.naturalSize.height, deny.naturalSize.height) }

    override func layout() {
        super.layout()
        let a = allow.naturalSize, d = deny.naturalSize
        allow.frame = NSRect(x: bounds.width - ceil(a.width), y: (bounds.height - a.height) / 2, width: ceil(a.width), height: a.height)
        deny.frame = NSRect(x: allow.frame.minX - Metrics.space1 - ceil(d.width), y: (bounds.height - d.height) / 2,
                            width: ceil(d.width), height: d.height)
    }
}

/// One of ``SidebarAnswerButtons``: its title, then its key in the caption's ink, on a chip sized to
/// its text. The pointer over it lifts the fill, a press darkens it (the sidebar's chrome fills).
final class SidebarAnswerButton: NSView {
    var onPress: (() -> Void)?
    private let title = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    private let keyLabel = SidebarRowView.label(font: Typography.caption)
    private let prominent: Bool
    private var hovering = false, pressing = false
    private var pointerHover: PointerHover?

    init(title text: String, key: String, label: String, prominent: Bool) {
        self.prominent = prominent
        super.init(frame: .zero)
        wantsLayer = true
        title.setString(text)
        keyLabel.setString(key)
        [title, keyLabel].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp(Strings.answerKeyHelp(key))
        pointerHover = PointerHover(self) { [weak self] hovering in
            self?.hovering = hovering
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// The title and keycap with the side padding a quiet chip takes.
    var naturalSize: NSSize {
        let t = title.naturalSize, k = keyLabel.naturalSize
        return NSSize(width: ceil(t.width) + Metrics.space1 + ceil(k.width) + 2 * Metrics.space2,
                      height: ceil(max(t.height, k.height)) + Metrics.space1)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress, !isHiddenOrHasHiddenAncestor else { return false }
        onPress()
        return true
    }

    /// A click in a window that is not key answers too, as the row's own buttons do.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressing = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func layout() {
        super.layout()
        let t = title.naturalSize, k = keyLabel.naturalSize
        title.frame = NSRect(x: Metrics.space2, y: (bounds.height - t.height) / 2, width: ceil(t.width), height: t.height)
        keyLabel.frame = NSRect(x: title.frame.maxX + Metrics.space1, y: (bounds.height - k.height) / 2,
                                width: ceil(k.width), height: k.height)
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme {
            title.setColor(prominent ? Palette.textPrimary : Palette.textSecondary)
            keyLabel.setColor(Palette.textTertiary)
            guard let layer else { return }
            layer.cornerRadius = Metrics.insetCornerRadius
            layer.cornerCurve = .continuous
            let rest = prominent ? Palette.badgeFill : nil
            let fill = pressing ? Palette.pressedFill
                : hovering && DesignSettings.shared.showsHoverFills ? (rest == nil ? Palette.hoverFill : ChromeHover.raisedHoverFill) : rest
            ChromeHover.paint(layer, fill, animated: window != nil, pressed: pressing)
        }
    }
}
