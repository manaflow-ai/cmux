import AppKit
import CmuxNextDesign

/// One grouped card of the Chief Settings popover (Leo 2026-10-21, #89: "a real settings page:
/// glass, with grouped cards"): the sidebar cards' glass surface (``CardSurfaceView``, a veil
/// over the popover's own glass with the top-lit rim, opaque under Reduce Transparency), a
/// header with its symbol and title, and its rows under it.
@MainActor
final class HomeChiefSettingsCard: NSView {
    /// The space between the card's edge and its content.
    static var padding: CGFloat { Metrics.space3 }
    let surface = CardSurfaceView(cornerRadius: Metrics.space3)
    let header: NSStackView
    /// The card's rows, top to bottom, each the card's full inner width.
    let body = NSStackView()
    private let stack = NSStackView()

    /// - Parameters:
    ///   - title: The header's title; nil for a card whose `titleView` names it.
    ///   - symbol: The SF Symbol beside the title.
    ///   - titleView: A header of the card's own (Diagnostics' disclosure) in place of the title.
    ///   - accessory: A control at the header's trailing edge.
    init(title: String?, symbol: String, identifier: String, titleView: NSView? = nil, accessory: NSView? = nil) {
        let icon = ThemedImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        icon.ink = .secondary
        icon.cell?.setAccessibilityElement(false)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        var views: [NSView] = [icon]
        if let titleView {
            views.append(titleView)
        } else if let title {
            let label = ThemedLabel(labelWithString: title)
            label.font = Typography.header
            label.ink = .secondary
            views.append(label)
        }
        if let accessory {
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            views += [spacer, accessory]
        }
        header = NSStackView(views: views)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(identifier)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Metrics.space2
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = Metrics.space3
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        for view in [header, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        addSubview(stack)
        let inset = Self.padding
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }

    /// Adds `view` as the card's next row: its full inner width, or at its own width at the
    /// leading edge (`fills` false: a link).
    func add(_ view: NSView, fills: Bool = true) {
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addArrangedSubview(view)
        if fills { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
    }
}

/// One settings row in a card: the title at the leading edge, the control at the trailing edge,
/// and under them, when given, one line that says what the row changes. The control's superview
/// is the row, so hiding `control.superview` hides the whole row, its line included.
@MainActor
final class HomeChiefSettingsRow: NSView {
    /// The width of a row's popup (Backend, Model, Effort, Speed), so their edges line up.
    static let pickerWidth: CGFloat = 176
    let title: ThemedLabel
    let help: ThemedLabel?

    /// - Parameter wrapWidth: The width the line under the row wraps at (the card's inner width).
    init(_ title: String, control: NSView, help: String? = nil, wrapWidth: CGFloat) {
        self.title = ThemedLabel(labelWithString: title)
        self.help = help.map { ThemedLabel(wrappingLabelWithString: $0) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.title.font = Typography.body
        self.title.lineBreakMode = .byTruncatingTail
        self.title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        for view in [self.title, control] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            self.title.leadingAnchor.constraint(equalTo: leadingAnchor),
            self.title.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -Metrics.space2),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
        ]
        // A one-line control (a popup, a switch) centers its title; a taller one (the pet's
        // characters) keeps its title on its first line.
        if control is NSButton || control is NSSwitch {
            constraints.append(self.title.centerYAnchor.constraint(equalTo: control.centerYAnchor))
        } else {
            constraints.append(self.title.topAnchor.constraint(equalTo: control.topAnchor, constant: Metrics.space1))
        }
        if control is NSPopUpButton { constraints.append(control.widthAnchor.constraint(equalToConstant: Self.pickerWidth)) }
        constraints.append(self.title.bottomAnchor.constraint(lessThanOrEqualTo: control.bottomAnchor))
        if let line = self.help {
            line.font = Typography.caption
            line.ink = .tertiary
            line.translatesAutoresizingMaskIntoConstraints = false
            line.preferredMaxLayoutWidth = wrapWidth
            addSubview(line)
            constraints += [
                line.topAnchor.constraint(equalTo: control.bottomAnchor, constant: Metrics.space1),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.trailingAnchor.constraint(equalTo: trailingAnchor),
                line.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(control.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { true }
}
