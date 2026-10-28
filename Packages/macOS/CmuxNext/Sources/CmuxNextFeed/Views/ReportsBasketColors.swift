import AppKit
import CmuxNextDesign

/// The reports basket's colors as AppKit values, resolved with the panel's other colors
/// (``FeedColors/resolved(background:)``) inside the host's theme scope. Until a host resolves,
/// the app theme's (`ThemeTokens.unresolved`), never macOS's grays.
struct ReportsBasketColors: Equatable {
    var background = ThemeTokens.unresolved.contentBackground.withAlpha(1).nsColor
    var primary = ThemeTokens.unresolved.textPrimary.nsColor
    var secondary = ThemeTokens.unresolved.textSecondary.nsColor
    var tertiary = ThemeTokens.unresolved.textTertiary.nsColor
    var selection = ThemeTokens.unresolved.selectionFill.nsColor
    var separator = ThemeTokens.unresolved.separator.nsColor
    var danger = ThemeTokens.unresolved.danger.nsColor
    /// Draw hairlines at all (`appearance.borders`).
    var borders = true

    /// Reads the chrome tokens; callers run it inside `performWithTheme`.
    // theme-scoped
    static func resolved(background: NSColor) -> ReportsBasketColors {
        // Static colors: dynamic ones would re-resolve outside the theme scope.
        func fixed(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
        return ReportsBasketColors(
            background: fixed(background), primary: fixed(Palette.textPrimary),
            secondary: fixed(Palette.textSecondary), tertiary: fixed(Palette.textTertiary),
            selection: fixed(Palette.selectionFill), separator: fixed(Palette.separator),
            danger: fixed(Palette.danger), borders: Borders.drawsLines)
    }
}

/// A hairline that disappears under `appearance.borders = none` (a 6 pt gap instead), the AppKit
/// twin of the panel's `FeedHairline`.
final class ReportsBasketHairline: NSView {
    private let vertical: Bool
    private lazy var thickness = (vertical ? widthAnchor : heightAnchor).constraint(equalToConstant: 1)

    init(vertical: Bool = false) {
        self.vertical = vertical
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        thickness.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ colors: ReportsBasketColors) {
        thickness.constant = colors.borders ? 1 : 6
        layer?.backgroundColor = (colors.borders ? colors.separator : .clear).cgColor
    }
}

/// Views the basket's parts share.
enum ReportsBasketText {
    static func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = TypeScale.regular,
                      rounded: Bool = false, lines: Int = 1) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        label.font = rounded ? font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font : font
        label.isSelectable = false
        label.maximumNumberOfLines = lines
        label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func symbol(_ name: String, size: CGFloat) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        let view = NSImageView(image: image ?? NSImage())
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 0,
                      alignment: NSLayoutConstraint.Attribute = .leading, insets: CGFloat = 0) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        // Fill, not gravity areas: a part with no intrinsic size (the list, the detail) takes the room left.
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: insets, left: insets, bottom: insets, right: insets)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// A centered column of `views` (the empty and nothing-selected states).
    static func centered(_ views: [NSView], padding: CGFloat) -> NSView {
        let stack = Self.stack(views, spacing: 8, alignment: .centerX)
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -2 * padding),
        ])
        // Wrapping lines stay inside the column.
        for view in views where (view as? NSTextField)?.maximumNumberOfLines == 0 {
            view.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -2 * padding).isActive = true
        }
        return box
    }

    /// Lets `view` take the room its stack has left along `orientation` (and give it up first).
    static func flexible(_ view: NSView, _ orientation: NSLayoutConstraint.Orientation) {
        view.setContentHuggingPriority(.init(1), for: orientation)
        view.setContentCompressionResistancePriority(.init(1), for: orientation)
    }

    /// A scroll view over `content`, as wide as its clip view (never under a legacy scroller) and
    /// pinned to its top (short content sits at the top).
    static func scroll(_ content: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        let document = TopDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.embed(content)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }

    /// A document view whose origin is its top-left.
    private final class TopDocument: NSView {
        override var isFlipped: Bool { true }
    }
}
