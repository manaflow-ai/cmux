import AppKit

/// Small AppKit building blocks of the pane chrome: labels, symbols, a
/// borderless text button with a hover fill, and a pill badge.
enum RemoteChrome {
    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func wrapping(_ text: String, size: CGFloat, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.alignment = .center
        field.preferredMaxLayoutWidth = width
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        let view = NSImageView(image: image ?? NSImage())
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    static func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 16),
        ])
        return line
    }

    static func row(_ views: [NSView], spacing: CGFloat, insets: NSEdgeInsets) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

/// A borderless chrome button: optional symbol, title, a hover fill drawn
/// with the theme's hover color (no accent), and an action closure.
final class RemoteChromeButton: NSButton {
    var onPress: (() -> Void)?
    private var hoverFill = NSColor.clear
    private var restingFill = NSColor.clear
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(title: String, symbol: String? = nil, height: CGFloat = 26) {
        super.init(frame: .zero)
        self.title = title
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            imageHugsTitle = true
        }
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 12, weight: .medium)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = height / 2
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        target = self
        action = #selector(pressed)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 18, height: base.height)
    }

    /// `fill` is the resting background (a selected segment); hover draws over it.
    func apply(text: NSColor, hover: NSColor, fill: NSColor = .clear) {
        contentTintColor = text
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: text, .font: font ?? .systemFont(ofSize: 12, weight: .medium),
        ])
        hoverFill = hover
        restingFill = fill
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isHovering ? hoverFill : restingFill).cgColor
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    @objc private func pressed() { onPress?() }
}
