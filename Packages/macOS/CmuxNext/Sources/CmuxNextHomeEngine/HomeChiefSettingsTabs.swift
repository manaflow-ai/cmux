import AppKit
import CmuxNextDesign

/// A round or pill button of the Chief's profile page: its fill follows hover and press, and the
/// keyboard's focus ring follows its shape.
@MainActor
class HomeChiefCardButton: NSButton {
    private(set) var isHovering = false
    private(set) var isPressed = false
    private var tracking: NSTrackingArea?

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Draws the button's state, in its theme.
    func applyTheme() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyTheme()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyTheme()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
        applyTheme()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = layer?.cornerRadius ?? 0
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// A profile card's round close button.
@MainActor
final class HomeChiefCardCloseButton: HomeChiefCardButton {
    init(label: String, target: AnyObject, action: Selector, size: CGFloat = 36, symbolSize: CGFloat = 15) {
        super.init(cornerRadius: size / 2)
        self.target = target
        self.action = action
        title = ""
        imagePosition = .imageOnly
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .regular)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: label)
        setAccessibilityLabel(label)
        themedToolTip = label
        layer?.borderWidth = 1
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        applyTheme()
    }

    override func applyTheme() {
        performWithTheme {
            layer?.backgroundColor = (isHovering || isPressed ? Palette.pressedFill : Palette.hoverFill).cgColor
            layer?.borderColor = Palette.paneBorder.cgColor
            contentTintColor = Palette.textPrimary
        }
    }
}

/// The Chief profile page's tabs: quiet labels, the selected one in a pill. Rest: secondary ink, no fill. Hover:
/// primary ink. Press: the hover fill. Selected: primary ink on the pill. Keyboard focus: the
/// system ring around the pill's shape.
@MainActor
final class HomeChiefSettingsTabs: NSStackView {
    enum Tab: CaseIterable {
        case details, computer

        var title: String {
            switch self {
            case .details: HomeEngineStrings.tabDetails
            case .computer: HomeEngineStrings.tabComputer
            }
        }
    }

    /// A tab was chosen by the person (not by ``select(_:)``).
    var onPick: (Tab) -> Void = { _ in }
    private(set) var selected: Tab = .details
    private var pills: [(tab: Tab, pill: Pill)] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 2
        setAccessibilityRole(.radioGroup)
        for tab in Tab.allCases {
            let pill = Pill(title: tab.title, target: self, action: #selector(picked(_:)))
            pills.append((tab, pill))
            addArrangedSubview(pill)
        }
        select(.details)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func select(_ tab: Tab) {
        selected = tab
        for (candidate, pill) in pills { pill.isChosen = candidate == tab }
    }

    /// The tab's button (tests).
    func button(_ tab: Tab) -> NSButton? { pills.first { $0.tab == tab }?.pill }

    @objc private func picked(_ sender: NSButton) {
        guard let tab = pills.first(where: { $0.pill === sender })?.tab else { return }
        select(tab)
        onPick(tab)
    }

    private final class Pill: HomeChiefCardButton {
        static let height: CGFloat = 26
        static let padding: CGFloat = 8
        static var font: NSFont { Typography.system(size: TypeScale.field, weight: TypeScale.regular) }
        private let text: String
        var isChosen = false { didSet { applyTheme() } }

        init(title: String, target: AnyObject, action: Selector) {
            text = title
            super.init(cornerRadius: Self.height / 2)
            self.target = target
            self.action = action
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(title)
            let width = ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 2 * Self.padding
            NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: width), heightAnchor.constraint(equalToConstant: Self.height)])
            applyTheme()
        }

        override func applyTheme() {
            setAccessibilityValue(isChosen)
            performWithTheme {
                layer?.backgroundColor = isChosen || isPressed ? Palette.hoverFill.cgColor : nil
                let ink = isChosen || isHovering ? Palette.textPrimary : Palette.textSecondary
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                attributedTitle = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: ink, .paragraphStyle: style])
            }
        }
    }
}
