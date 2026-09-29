import AppKit
import CmuxNextDesign

/// Glass dropdown under the address bar. A separate non-activating child
/// panel, so it stays above child-window engines (CEF) and never takes key
/// status from the field being edited.
final class OmniboxSuggestionPanel {
    var onPick: ((Int) -> Void)?

    private var panel: SuggestionWindow?
    private let stack = NSStackView()
    private var rows: [SuggestionRowView] = []

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ suggestions: [BrowserSuggestion], selected: Int?, below anchor: NSView, in window: NSWindow) {
        let panel = panel ?? makePanel()
        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let row = SuggestionRowView(suggestion: suggestion)
            row.onClick = { [weak self] in self?.onPick?(index) }
            row.isSelected = index == selected
            return row
        }
        rows.forEach { stack.addArrangedSubview($0) }

        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let screenRect = window.convertToScreen(anchorRect)
        let height = CGFloat(rows.count) * SuggestionRowView.height + 12
        let frame = NSRect(x: screenRect.minX, y: screenRect.minY - 6 - height, width: screenRect.width, height: height)

        panel.appearance = window.effectiveAppearance
        let wasVisible = panel.isVisible
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            Motion.animate(duration: 0.1) { panel.animator().alphaValue = 1 }
        }
    }

    func select(_ index: Int) {
        for (offset, row) in rows.enumerated() {
            row.isSelected = offset == index
        }
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> SuggestionWindow {
        let window = SuggestionWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = OverlayBackingView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
        ])
        let glass = Glass.makePanel(content: content, style: .regular, cornerRadius: 12)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        window.contentView = glass
        panel = window
        return window
    }
}

final class SuggestionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SuggestionRowView: NSView {
    static let height: CGFloat = 32

    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateFill() } }
    private var isHovering = false { didSet { updateFill() } }
    private var tracking: NSTrackingArea?

    init(suggestion: BrowserSuggestion) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Metrics.itemCornerRadius

        let symbol = switch suggestion.kind {
        case .navigate: "globe"
        case .search: "magnifyingglass"
        case .history: "clock"
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage())
        icon.contentTintColor = Palette.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: suggestion.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = Palette.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = NSTextField(labelWithString: suggestion.detail.isEmpty ? "" : "— \(suggestion.detail)")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Palette.textSecondary
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

        let stack = NSStackView(views: [icon, title, detail])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.widthAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel([suggestion.title, suggestion.detail].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let color: NSColor = isSelected ? Palette.selectionFill : (isHovering ? Palette.hoverFill : .clear)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
