import AppKit
import CmuxNextDesign

/// Fills `BrowserChromeView.extensionSlot` with one button per extension
/// action of the bound tab (CEF), mirroring Chrome's toolbar: pinned and
/// unpinned actions in the order Chromium reports, icon plus native badge.
/// Click runs the action (popup or `onClicked`); right click shows
/// Chromium's action menu.
final class ExtensionActionToolbar {
    private let slot: NSStackView
    private var host: (any BrowserExtensionActionHosting)?
    private weak var anchorView: NSView?
    private var observation: ObservationLoop?
    private var buttons: [String: ExtensionActionButton] = [:]

    init(slot: NSStackView) {
        self.slot = slot
    }

    /// Binds the toolbar to a tab; nil (or a tab without extensions) empties it.
    func bind(_ tab: any BrowserTab) {
        observation?.cancel()
        observation = nil
        host = tab as? any BrowserExtensionActionHosting
        anchorView = tab.contentView
        guard host != nil else {
            render([])
            return
        }
        observation = ObservationLoop { [weak self] in
            guard let self, let host = self.host else { return }
            self.render(host.extensionActions)
        }
    }

    private func render(_ actions: [CEFExtensionAction]) {
        let ids = Set(actions.map(\.id))
        for (id, button) in buttons where !ids.contains(id) {
            slot.removeArrangedSubview(button)
            button.removeFromSuperview()
            buttons[id] = nil
        }
        for (index, action) in actions.enumerated() {
            let button = buttons[action.id] ?? makeButton(for: action.id)
            button.update(action)
            if let current = slot.arrangedSubviews.firstIndex(of: button) {
                guard current != index else { continue }
                slot.removeArrangedSubview(button)
            }
            slot.insertArrangedSubview(button, at: min(index, slot.arrangedSubviews.count))
        }
    }

    private func makeButton(for id: String) -> ExtensionActionButton {
        let button = ExtensionActionButton(actionID: id)
        button.onRun = { [weak self, weak button] in
            guard let self, let button, let anchor = self.anchorView else { return }
            let rect = button.convert(button.bounds, to: anchor)
            self.host?.runExtensionAction(id, anchor: rect)
        }
        button.onMenu = { [weak self] point in
            self?.host?.showExtensionActionMenu(id, atScreenPoint: point)
        }
        buttons[id] = button
        return button
    }
}

/// One extension action: icon, native badge, gray hover and press fills.
final class ExtensionActionButton: NSButton {
    let actionID: String
    var onRun: (() -> Void)?
    var onMenu: ((CGPoint) -> Void)?

    private let badge = CATextLayer()
    private let density = DensityBinding()
    private var isHovering = false { didSet { updateFill() } }
    private var tracking: NSTrackingArea?

    init(actionID: String) {
        self.actionID = actionID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        target = self
        action = #selector(run)
        badge.alignmentMode = .center
        badge.isHidden = true
        layer?.addSublayer(badge)
        NSLayoutConstraint.activate([
            density.bind(widthAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.controlHeight },
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { BrowserMetrics.controlHeight },
        ])
        density.update { [unowned self] in
            layer?.cornerRadius = BrowserMetrics.controlCornerRadius
            needsLayout = true
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ action: CEFExtensionAction) {
        let size = BrowserMetrics.glyphSize
        if let data = action.iconPNG, let icon = NSImage(data: data) {
            icon.size = NSSize(width: size, height: size)
            image = icon
        } else {
            image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: action.name)
        }
        toolTip = action.title.isEmpty ? action.name : action.title
        setAccessibilityLabel(action.name)
        isEnabled = action.isEnabled
        alphaValue = action.isEnabled ? 1 : 0.45
        badge.string = action.badge
        badge.isHidden = action.badge.isEmpty
        if let rgba = CEFExtensionAction.rgba(action.badgeColor) {
            badge.backgroundColor = CGColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
        }
        let text = CEFExtensionAction.rgba(action.badgeTextColor) ?? (1, 1, 1, 1)
        badge.foregroundColor = CGColor(srgbRed: text.red, green: text.green, blue: text.blue, alpha: text.alpha)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let font = BrowserMetrics.captionFont
        let fontSize = font.pointSize * 0.8
        badge.font = font
        badge.fontSize = fontSize
        badge.contentsScale = window?.backingScaleFactor ?? 2
        let height = ceil(fontSize + 2)
        let width = max(height, ceil((badge.string as? String ?? "").size(withAttributes: [.font: font.withSize(fontSize)]).width) + 4)
        badge.cornerRadius = height / 2
        badge.frame = CGRect(x: bounds.maxX - width, y: 0, width: width, height: height)
    }

    @objc private func run() { onRun?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        onMenu?(point)
    }

    override var isHighlighted: Bool { didSet { updateFill() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let color: NSColor = isHighlighted ? Palette.selectionFill : (isHovering ? Palette.hoverFill : .clear)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
