import AppKit
import CmuxNextDesign

/// A label in one of Mac Screen's inks. A wrapping one takes the width its
/// container gives it and reports the height of its lines at that width.
@MainActor
final class MacScreenText: NSTextField, MacScreenInked {
    private let ink: KeyPath<MacScreenColors, NSColor>
    private let wraps: Bool

    init(_ text: String, font: NSFont, ink: KeyPath<MacScreenColors, NSColor> = \.primary, wraps: Bool = false,
         alignment: NSTextAlignment = .natural, width: CGFloat? = nil) {
        self.ink = ink
        self.wraps = wraps
        super.init(frame: .zero)
        stringValue = text
        self.font = font
        self.alignment = alignment
        isBordered = false
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        if wraps {
            usesSingleLineMode = false
            maximumNumberOfLines = 0
            lineBreakMode = .byWordWrapping
            // SwiftUI Text's breaking: no one-word last line (it pushes a word down with it).
            lineBreakStrategy = .standard
            cell?.wraps = true
            cell?.isScrollable = false
            cell?.truncatesLastVisibleLine = false
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .vertical)
            if let width { preferredMaxLayoutWidth = width }
        } else {
            usesSingleLineMode = true
            maximumNumberOfLines = 1
            lineBreakMode = .byTruncatingTail
            cell?.wraps = false
            cell?.isScrollable = false
            cell?.truncatesLastVisibleLine = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ colors: MacScreenColors) {
        textColor = colors[keyPath: ink]
    }

    /// A wrapping label lays its lines out at the width it was given.
    override func layout() {
        super.layout()
        fitLines()
    }

    /// A wrapping label takes its frame's width as its line width; true when that changed its height.
    @discardableResult
    func fitLines() -> Bool {
        guard wraps, bounds.width > 0, abs(preferredMaxLayoutWidth - bounds.width) > 0.5 else { return false }
        preferredMaxLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
        return true
    }
}

/// An SF Symbol in one of Mac Screen's inks.
@MainActor
final class MacScreenGlyph: NSImageView, MacScreenInked {
    private let ink: KeyPath<MacScreenColors, NSColor>
    private var pointSize: CGFloat

    init(_ symbol: String, font: NSFont, ink: KeyPath<MacScreenColors, NSColor> = \.secondary, width: CGFloat? = nil) {
        self.ink = ink
        pointSize = font.pointSize
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
        imageScaling = .scaleNone
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ colors: MacScreenColors) {
        contentTintColor = colors[keyPath: ink]
    }

    /// Draws the symbol at `font`'s size (a type scale change).
    func resize(to font: NSFont) {
        guard pointSize != font.pointSize else { return }
        pointSize = font.pointSize
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
    }
}

/// A filled view in one of Mac Screen's colors: a status dot (a circle), a
/// hairline, a group card or a popup card (rounded, with a hairline border
/// while `appearance.borders` is on).
@MainActor
final class MacScreenFill: NSView, MacScreenInked {
    enum Shape {
        case rect
        case circle
        case rounded(CGFloat)
    }

    var fill: KeyPath<MacScreenColors, NSColor> {
        didSet { if let colors { apply(colors) } }
    }
    /// The hairline variant: the separator, or a faint fill with borders off.
    private let hairline: Bool
    private let bordered: Bool
    private let shape: Shape
    private var colors: MacScreenColors?

    init(_ fill: KeyPath<MacScreenColors, NSColor>, shape: Shape = .rect, bordered: Bool = false, hairline: Bool = false) {
        self.fill = fill
        self.shape = shape
        self.bordered = bordered
        self.hairline = hairline
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        if case let .rounded(radius) = shape {
            layer?.cornerRadius = radius
            layer?.cornerCurve = .continuous
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A circle of `side` points in `fill`.
    static func dot(_ fill: KeyPath<MacScreenColors, NSColor>, side: CGFloat) -> MacScreenFill {
        let dot = MacScreenFill(fill, shape: .circle)
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: side), dot.heightAnchor.constraint(equalToConstant: side)])
        return dot
    }

    /// A one-point line between rows: the separator, or a faint fill with borders off.
    static func divider() -> MacScreenFill {
        let line = MacScreenFill(\.separator, hairline: true)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        roundCircle()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        roundCircle()
    }

    private func roundCircle() {
        if case .circle = shape { layer?.cornerRadius = min(bounds.width, bounds.height) / 2 }
    }

    func apply(_ colors: MacScreenColors) {
        self.colors = colors
        let color = hairline && !colors.borders ? colors.hover : colors[keyPath: fill]
        layer?.backgroundColor = color.cgColor
        layer?.borderWidth = bordered && colors.borders ? 1 : 0
        layer?.borderColor = colors.separator.cgColor
    }
}

/// A view that takes no room and no clicks: the `Spacer` of a row.
@MainActor
final class MacScreenSpacer: NSView {
    init(min: CGFloat = 0) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        if min > 0 { widthAnchor.constraint(greaterThanOrEqualToConstant: min).isActive = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum MacScreenStack {
    /// A row (`HStack`) or a column (`VStack`) of `views`.
    static func make(_ orientation: NSUserInterfaceLayoutOrientation, spacing: CGFloat, alignment: NSLayoutConstraint.Attribute,
                     _ views: [NSView] = [], insets: NSEdgeInsets = NSEdgeInsetsZero) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = spacing
        stack.alignment = alignment
        stack.distribution = .fill
        stack.edgeInsets = insets
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.detachesHiddenViews = true
        return stack
    }

    /// Adds `view` to a column, as wide as the column (inside its insets).
    static func addFullWidth(_ view: NSView, to column: NSStackView) {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -(column.edgeInsets.left + column.edgeInsets.right)).isActive = true
    }
}

/// A row that runs `onDoubleClick` on a double click anywhere but its controls.
@MainActor
final class MacScreenRowView: NSView {
    var onDoubleClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Labels and glyphs take no clicks here: the row does.
        if let hit, hit is NSButton { return hit }
        return hit == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}
