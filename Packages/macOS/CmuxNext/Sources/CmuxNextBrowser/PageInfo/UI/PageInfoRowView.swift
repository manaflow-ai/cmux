import AppKit
import CmuxNextDesign

/// One bubble row (Chromium's `RichHoverButton`): icon, title, optional
/// subtitle, and a trailing chevron, external-link mark, or toggle. Gray
/// hover and press fills; keyboard focus draws a gray ring. Space or Return
/// activates, as a click does.
final class PageInfoRowView: NSView {
    enum Accessory {
        case none
        case chevron
        case externalLink
        case toggle(Bool)
    }

    var onActivate: (() -> Void)?
    var onToggle: ((Bool) -> Void)? {
        didSet { toggle?.onChange = onToggle }
    }

    private let iconView = ThemedImageView()
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private var accessoryView: NSView?
    private(set) var toggle: PageInfoToggle?
    private var tracking: NSTrackingArea?
    private var isHovering = false { didSet { refreshFill() } }
    private var isPressed = false { didSet { refreshFill() } }
    private let isInteractive: Bool

    init(symbol: String?, title: String, subtitle: String? = nil, accessory: Accessory = .none,
         tint: @escaping @autoclosure () -> NSColor? = nil, interactive: Bool = true, identifier: String? = nil) {
        titleLabel = PageInfoStyle.label(title, font: PageInfoStyle.bodyFont, color: tint() ?? PageInfoStyle.text)
        subtitleLabel = PageInfoStyle.label(subtitle ?? "", font: PageInfoStyle.captionFont, color: PageInfoStyle.secondaryText)
        isInteractive = interactive
        super.init(frame: .zero)
        self.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        focusRingType = .none
        layer?.cornerRadius = PageInfoStyle.itemCornerRadius
        layer?.cornerCurve = .continuous
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = symbol.flatMap { PageInfoStyle.symbol($0) }
        iconView.themeTint = { tint() ?? PageInfoStyle.text }
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true

        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(texts)

        let trailing = makeAccessory(accessory)
        accessoryView = trailing
        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: subtitleLabel.isHidden ? PageInfoStyle.rowHeight : PageInfoStyle.rowHeightWithSubtitle),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PageInfoStyle.rowInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PageInfoStyle.iconColumn - PageInfoStyle.rowInset),
            texts.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: PageInfoStyle.rowInset),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
        ]
        if let trailing {
            addSubview(trailing)
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PageInfoStyle.rowInset),
                trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
                texts.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -PageInfoStyle.rowInset),
            ]
        } else {
            constraints.append(texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PageInfoStyle.rowInset))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(interactive ? .button : .staticText)
        setAccessibilityLabel([title, subtitle].compactMap(\.self).joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeAccessory(_ accessory: Accessory) -> NSView? {
        switch accessory {
        case .none:
            return nil
        case .chevron, .externalLink:
            let image = ThemedImageView(image: PageInfoStyle.symbol(
                { if case .chevron = accessory { "chevron.right" } else { "arrow.up.forward.square" } }(),
                size: PageInfoStyle.iconSize - 2) ?? NSImage())
            image.themeTint = { PageInfoStyle.secondaryText }
            image.translatesAutoresizingMaskIntoConstraints = false
            return image
        case .toggle(let on):
            let toggle = PageInfoToggle()
            toggle.isOn = on
            self.toggle = toggle
            return toggle
        }
    }

    // MARK: Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard isInteractive else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return super.mouseDown(with: event) }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    /// A row with only a toggle flips it; other rows run `onActivate`.
    func activate() {
        if onActivate == nil, let toggle { toggle.flip() } else { onActivate?() }
    }

    override var acceptsFirstResponder: Bool { isInteractive }
    override var canBecomeKeyView: Bool { isInteractive }

    // The system focus ring is the accent color (blue); draw a gray one.
    override func becomeFirstResponder() -> Bool {
        showsFocus = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        showsFocus = false
        return super.resignFirstResponder()
    }

    private var showsFocus = false { didSet { refreshFill() } }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49: activate()          // Return, Enter, Space
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isInteractive else { return false }
        activate()
        return true
    }

    private func refreshFill() {
        layer?.borderWidth = Metrics.lineWidth(showsFocus ? 1.5 : 0)
        performWithTheme {
            let fill: NSColor = isPressed ? PageInfoStyle.pressed : (isHovering || showsFocus ? PageInfoStyle.hover : .clear)
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = PageInfoStyle.focusRing.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFill()
    }
}
