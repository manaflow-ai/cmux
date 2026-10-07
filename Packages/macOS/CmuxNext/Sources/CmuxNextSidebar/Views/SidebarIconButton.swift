import AppKit
import CmuxNextDesign
import QuartzCore

/// Small borderless icon button with the shared chrome hover and pressed
/// fills (`ChromeHover`, no blue).
final class SidebarIconButton: NSButton {
    private(set) lazy var hover = ChromeHover(self, behindContent: true)
    var onPress: (() -> Void)?

    /// Replacing the symbol or label redraws the button (a disclosure's chevron).
    var symbol: String { didSet { if symbol != oldValue { renderedSize = 0; renderSymbol() } } }
    private let weight: NSFont.Weight
    var label: String {
        didSet {
            guard label != oldValue else { return }
            setAccessibilityLabel(label)
            toolTip = label
            renderedSize = 0
            renderSymbol()
        }
    }
    /// Point size read at layout time so density changes apply live.
    private let pointSize: () -> CGFloat
    private var renderedSize: CGFloat = 0

    init(symbol: String, pointSize: @escaping () -> CGFloat = { Metrics.smallIconSize }, weight: NSFont.Weight = .semibold, label: String) {
        self.symbol = symbol
        self.weight = weight
        self.label = label
        self.pointSize = pointSize
        super.init(frame: .zero)
        renderSymbol()
        imagePosition = .imageOnly
        isBordered = false
        setAccessibilityLabel(label)
        toolTip = label
        wantsLayer = true
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    private func renderSymbol() {
        let size = pointSize()
        guard size != renderedSize else { return }
        renderedSize = size
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
    }

    override func layout() {
        super.layout()
        renderSymbol()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        performWithTheme {
            contentTintColor = hover.state.hovering || hover.state.pressed ? Palette.textPrimary : Palette.textSecondary
        }
        hover.refresh(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.updateTrackingAreas()
    }

    private func changeHover(_ change: (inout ChromeHover.State) -> Void) {
        change(&hover.state)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { changeHover { $0.hovering = true } }
    override func mouseExited(with event: NSEvent) { changeHover { $0.hovering = false } }

    /// NSButton tracks the click inside `super.mouseDown` and returns on release.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        changeHover { $0.pressed = true }
        super.mouseDown(with: event)
        changeHover { $0.pressed = false }
    }

    /// A button hidden under the pointer (the header + while the sidebar
    /// is not hovered) gets no exit event; it reappears without the fill.
    override func viewDidHide() {
        super.viewDidHide()
        changeHover { $0.hovering = false; $0.pressed = false }
    }
}
