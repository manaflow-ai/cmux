import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A view whose layer fill is a theme color, read again in its scope on every theme change.
class AppStoreSurfaceView: NSView {
    /// The fill, read inside `performWithTheme`; nil draws none.
    var fill: () -> NSColor? = { nil } {
        didSet { needsDisplay = true }
    }
    var corner: CGFloat = 0 {
        didSet { layer?.cornerRadius = corner }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        performWithTheme { layer?.backgroundColor = fill()?.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A row or card that opens something on a click (a listing, a category): the hover fill under the pointer,
/// the pressed fill while held. Buttons inside it take their own clicks.
final class AppStoreClickableView: AppStoreSurfaceView {
    private let handler: @MainActor () -> Void
    private let rest: () -> NSColor?
    private var pointerHover: PointerHover?
    private var isHovered = false
    private var isHeld = false

    init(rest: @escaping () -> NSColor? = { nil }, label: String, action: @escaping @MainActor () -> Void) {
        handler = action
        self.rest = rest
        super.init(frame: .zero)
        fill = { [weak self] in
            guard let self else { return nil }
            return ChromeHover.fillColor(ChromeHover.State(hovering: isHovered, pressed: isHeld), rest: rest())
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        pointerHover = PointerHover(self) { [weak self] hovering in
            self?.isHovered = hovering
            self?.needsDisplay = true
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isHeld = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHeld = false
        needsDisplay = true
        if inside { handler() }
    }

    override func accessibilityPerformPress() -> Bool {
        handler()
        return true
    }
}

/// A listing's icon: the package image, else cmux's own glyph for its symbol on the accent tile, else the
/// name's first letter. Rounded as an app icon (a share of its side, never a button corner).
final class AppStoreIconView: AppStoreSurfaceView {
    private let image = NSImageView()
    private let initial = ThemedLabel(labelWithString: "")
    private let side: CGFloat
    /// The symbol glyph draws in the on-accent ink.
    private var tintsGlyph = false

    init(item: AppStoreItem?, name: String, image loaded: NSImage?, side: CGFloat) {
        self.side = side
        super.init(frame: .zero)
        corner = (side * 0.225).rounded()
        layer?.masksToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        initial.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(initial)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            initial.centerXAnchor.constraint(equalTo: centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let loaded {
            image.image = loaded
            image.contentTintColor = nil
            fill = { nil }
            pin(image, inset: 0)
        } else if case .symbol(let symbol) = item?.icon {
            image.image = NSImage.icon(symbol: symbol, size: (side * 0.5).rounded())
            image.imageScaling = .scaleNone
            tintsGlyph = true
            fill = { Palette.accentFill }
            pin(image, inset: 0)
        } else {
            initial.stringValue = name.first.map { String($0).uppercased() } ?? ""
            initial.font = Typography.system(size: side >= 64 ? TypeScale.heading : TypeScale.title, weight: TypeScale.emphasis)
            initial.themeColor = { Palette.onAccent }
            fill = { Palette.accentFill }
        }
        setAccessibilityElement(false)
    }

    override func updateLayer() {
        super.updateLayer()
        guard tintsGlyph else { return }
        performWithTheme { image.contentTintColor = Palette.onAccent }
    }

    private func pin(_ view: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }
}

/// A screenshot with a hairline and the content's corner.
final class AppStoreShotView: AppStoreSurfaceView {
    init(image: NSImage, width: CGFloat, label: String) {
        super.init(frame: .zero)
        corner = Metrics.insetCornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        let ratio = image.size.width > 0 ? image.size.height / image.size.width : 0.625
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: (width * ratio).rounded()),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
    }

    override func updateLayer() {
        super.updateLayer()
        performWithTheme { layer?.borderColor = Palette.separator.cgColor }
    }
}

/// Builders the store's views share.
@MainActor
struct AppStoreLayout {
    /// A label in a type-scale font and a theme ink; `width` wraps it at that width.
    static func label(_ text: String, font: NSFont, ink: ThemeInk = .primary, width: CGFloat? = nil,
                      lines: Int = 0, selectable: Bool = false) -> ThemedLabel {
        let label = width == nil ? ThemedLabel(labelWithString: text) : ThemedLabel(wrappingLabelWithString: text)
        label.font = font
        label.ink = ink
        label.isSelectable = selectable
        label.translatesAutoresizingMaskIntoConstraints = false
        if let width {
            label.preferredMaxLayoutWidth = width
            label.maximumNumberOfLines = lines
            if lines > 0 { label.lineBreakMode = .byTruncatingTail; label.wraps = true }
        } else {
            label.lineBreakMode = .byTruncatingTail
        }
        return label
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat, alignment: NSLayoutConstraint.Attribute? = nil) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.spacing = spacing
        stack.alignment = alignment ?? (vertical ? .leading : .centerY)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// A view that takes the free room in a horizontal stack.
    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    static func fixedWidth(_ view: NSView, _ width: CGFloat) -> NSView {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    /// A section heading (`Shows up in`, `What's New`).
    static func heading(_ text: String) -> ThemedLabel {
        label(text, font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis))
    }

    /// A small rounded badge (Optional, Sensitive, Installed).
    static func badge(_ text: String) -> NSView {
        let box = AppStoreSurfaceView()
        box.fill = { Palette.hoverFill }
        box.corner = Metrics.insetCornerRadius
        let text = label(text, font: Typography.system(size: TypeScale.caption), ink: .secondary)
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Metrics.space1 + 1),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -(Metrics.space1 + 1)),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        return box
    }

    /// A centered state line (loading, empty, a failed read) with an optional Retry.
    static func state(_ text: String, detail: String? = nil, width: CGFloat, retry: (@MainActor () -> Void)? = nil) -> NSView {
        var views: [NSView] = [label(text, font: Typography.system(size: TypeScale.title, weight: TypeScale.emphasis), ink: .secondary)]
        if let detail { views.append(label(detail, font: Typography.body, ink: .tertiary, width: width, selectable: true)) }
        if let retry { views.append(AppStoreButton(AppStoreStrings.retry, style: .secondary, action: retry)) }
        let stack = stack(views, spacing: Metrics.space2, alignment: .centerX)
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space6, left: 0, bottom: Metrics.space6, right: 0)
        return stack
    }
}
