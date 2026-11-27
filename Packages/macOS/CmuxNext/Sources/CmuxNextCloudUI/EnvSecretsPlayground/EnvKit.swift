#if DEBUG
import AppKit
import CmuxNextDesign

// DEBUG ONLY (Environment Secrets Playground): the AppKit building blocks the three directions draw
// with. Plain views and stack views, no hosting bridge; every colour is a dynamic system colour, so a
// view follows its window's light or dark look. Pure helpers, kept file-scope as the playground is
// deleted after the pick.

/// A text label: one line by default, or wrapping to its width when `wraps` is true.
func envLabel(_ text: String, size: CGFloat = TypeScale.detail, weight: NSFont.Weight = .regular,
              color: NSColor = .labelColor, mono: Bool = false, digits: Bool = false, wraps: Bool = false,
              strike: Bool = false) -> NSTextField {
    let font: NSFont = mono ? .monospacedSystemFont(ofSize: size, weight: weight)
        : digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    if strike {
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ])
    }
    if wraps {
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.preferredMaxLayoutWidth = 0
    } else {
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.required, for: .horizontal)
    }
    return label
}

/// An SF Symbol in `color` at the text size `size`.
func envSymbol(_ name: String, size: CGFloat = TypeScale.detail, weight: NSFont.Weight = .regular,
               color: NSColor = .secondaryLabelColor) -> NSImageView {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? NSImage()
    let view = NSImageView(image: image)
    view.contentTintColor = color
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentCompressionResistancePriority(.required, for: .horizontal)
    return view
}

/// A symbol then a title, as a label with an icon.
func envIconLabel(_ title: String, symbol: String, size: CGFloat = TypeScale.detail, weight: NSFont.Weight = .regular,
                  color: NSColor = .labelColor, spacing: CGFloat = 4) -> NSStackView {
    envH([envSymbol(symbol, size: size, weight: weight, color: color),
          envLabel(title, size: size, weight: weight, color: color)], spacing: spacing, align: .firstBaseline)
}

/// A vertical stack. `fill`: every child takes the stack's full width (a child that should keep its own
/// width then sits in an ``envH(_:spacing:align:)`` with an ``envSpacer()``).
func envV(_ views: [NSView], spacing: CGFloat = 8, fill: Bool = false,
          align: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = align
    stack.spacing = spacing
    stack.detachesHiddenViews = true
    if fill {
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    return stack
}

/// A horizontal stack; `align` is `.centerY`, `.top` or `.firstBaseline`.
func envH(_ views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = align
    stack.spacing = spacing
    stack.detachesHiddenViews = true
    return stack
}

/// Empty room that takes what is left in a stack.
func envSpacer(minLength: CGFloat = 0) -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentHuggingPriority(.init(1), for: .vertical)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    view.setContentCompressionResistancePriority(.init(1), for: .vertical)
    if minLength > 0 { view.widthAnchor.constraint(greaterThanOrEqualToConstant: minLength).isActive = true }
    return view
}

/// A one-point separator line, horizontal unless `vertical`.
func envDivider(vertical: Bool = false) -> NSView {
    let line = EnvBox(nil, fill: .separatorColor)
    if vertical { line.widthAnchor.constraint(equalToConstant: 1).isActive = true } else {
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    return line
}

/// `view` pinned to a fixed width (and height, when given).
@discardableResult
func envSized<V: NSView>(_ view: V, width: CGFloat? = nil, height: CGFloat? = nil) -> V {
    view.translatesAutoresizingMaskIntoConstraints = false
    if let width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
    if let height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    return view
}

/// `view` with its width capped at `maxWidth`, left-aligned in the full width it is given.
func envMaxWidth(_ view: NSView, _ maxWidth: CGFloat) -> NSView {
    let holder = NSView()
    holder.translatesAutoresizingMaskIntoConstraints = false
    view.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(view)
    let fit = view.widthAnchor.constraint(equalTo: holder.widthAnchor)
    fit.priority = .defaultHigh
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: holder.leadingAnchor), view.topAnchor.constraint(equalTo: holder.topAnchor),
        view.bottomAnchor.constraint(equalTo: holder.bottomAnchor), view.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        view.widthAnchor.constraint(lessThanOrEqualTo: holder.widthAnchor), fit,
    ])
    return holder
}

/// A vertical scroll view over `content`, which takes the scroll view's width and starts at the top.
func envScroll(_ content: NSView) -> NSScrollView {
    let scroll = OverlayScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let document = EnvFlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(content)
    scroll.documentView = document
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: document.topAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: document.trailingAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    return scroll
}

/// A sideways scroll view over `content`: as tall as the content and at least as wide as itself; content
/// wider than the scroll view scrolls sideways instead of wrapping or being cut off (a terminal's lines).
func envHScroll(_ content: NSView) -> NSScrollView {
    let scroll = OverlayScrollView()
    scroll.drawsBackground = false
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = false
    scroll.autohidesScrollers = true
    scroll.verticalScrollElasticity = .none
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let document = EnvFlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(content)
    scroll.documentView = document
    // The document takes the scroll view's width unless the content needs more.
    let fit = document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
    fit.priority = .defaultLow
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: document.topAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
        content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        document.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor), fit,
        document.widthAnchor.constraint(greaterThanOrEqualTo: content.widthAnchor),
        scroll.heightAnchor.constraint(equalTo: document.heightAnchor),
    ])
    return scroll
}

/// A grid of rows (each row the same number of cells); `nil` cells are empty. Column 0 hugs its text.
func envGrid(_ rows: [[NSView?]], columnSpacing: CGFloat = 14, rowSpacing: CGFloat = 7,
             rowAlign: NSGridRow.Alignment = .firstBaseline) -> NSGridView {
    let grid = NSGridView(views: rows.map { $0.map { $0 ?? NSGridCell.emptyContentView } })
    grid.columnSpacing = columnSpacing
    grid.rowSpacing = rowSpacing
    grid.rowAlignment = rowAlign
    grid.xPlacement = .leading
    grid.yPlacement = .center
    return grid
}

/// Adds a full-width separator row to `grid` after its last row.
func envGridDivider(_ grid: NSGridView) {
    let row = grid.addRow(with: [envDivider()])
    row.mergeCells(in: NSRange(location: 0, length: grid.numberOfColumns))
    row.cell(at: 0).xPlacement = .fill
}

/// A flipped plain view: a scroll view's document, or a container laid out from the top.
final class EnvFlippedView: NSView {
    override var isFlipped: Bool { true }
}
#endif
