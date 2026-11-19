public import AppKit
import CmuxNextDesign

/// One toggle of the Home transcript header's top-right cluster (Claude desktop's panel buttons):
/// a panel beside Home that the button opens and, clicked again, closes. The host says what each
/// one is and whether its panel is open; the bar only draws and reports clicks.
public struct HomeHeaderPanelItem: Equatable, Sendable {
    /// Stable id, also the button's accessibility identifier suffix (`cmux.home.headerPanel.<id>`).
    public var id: String
    /// SF Symbol while closed, and while open (drawn in the theme's accent).
    public var symbol: String
    public var onSymbol: String
    /// The localized name: the button's VoiceOver label and its tooltip.
    public var label: String
    /// The toggle's keyboard shortcut for the tooltip ("⌥⌘B"); nil for none.
    public var shortcut: String?
    /// The panel is open: the button shows on.
    public var isOn: Bool

    public init(id: String, symbol: String, onSymbol: String? = nil, label: String, shortcut: String? = nil, isOn: Bool) {
        self.id = id
        self.symbol = symbol
        self.onSymbol = onSymbol ?? symbol
        self.label = label
        self.shortcut = shortcut
        self.isOn = isOn
    }
}

/// The header's trailing cluster: quiet icon toggles (``HomeHeaderButton``: no pill at rest, the
/// theme's hover pill, the accent glyph when on, never the system blue, no border), left to right
/// in the host's order. Its gaps are not hits, so they drag the window like the rest of the header.
final class HomeHeaderPanelBar: NSView {
    static let buttonSize: CGFloat = 28
    static let spacing: CGFloat = 2

    /// A click (or Space with the keyboard) on the toggle with this id.
    var onToggle: (String) -> Void = { _ in }
    private(set) var items: [HomeHeaderPanelItem] = []
    private(set) var buttons: [HomeHeaderButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.home.headerPanels")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Shows `items`: the same ids keep their buttons (only state and text change), others rebuild.
    func set(_ items: [HomeHeaderPanelItem]) {
        guard items != self.items else { return }
        if items.map(\.id) != self.items.map(\.id) || zip(items, self.items).contains(where: { $0.symbol != $1.symbol || $0.onSymbol != $1.onSymbol }) {
            for button in buttons { button.removeFromSuperview() }
            buttons = items.map { item in
                let button = HomeHeaderButton(symbol: item.symbol, onSymbol: item.onSymbol, label: item.label,
                                              identifier: "cmux.home.headerPanel.\(item.id)")
                button.target = self
                button.action = #selector(clicked(_:))
                addSubview(button)
                return button
            }
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
        self.items = items
        for (button, item) in zip(buttons, items) {
            button.setAccessibilityLabel(item.label)
            button.themedToolTip = item.label
            button.themedToolTipShortcut = item.shortcut
            button.isOn = item.isOn
        }
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(buttons.count)
        return NSSize(width: n == 0 ? 0 : n * Self.buttonSize + (n - 1) * Self.spacing, height: Self.buttonSize)
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * (Self.buttonSize + Self.spacing), y: (bounds.height - Self.buttonSize) / 2,
                                  width: Self.buttonSize, height: Self.buttonSize)
        }
    }

    /// Only the buttons are hits; the gaps between them belong to the header (window drag).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return buttons.first { !$0.isHidden && $0.frame.contains(p) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for button in buttons { button.applyTint() }
    }

    @objc private func clicked(_ sender: HomeHeaderButton) {
        guard let index = buttons.firstIndex(where: { $0 === sender }), items.indices.contains(index) else { return }
        onToggle(items[index].id)
    }
}
