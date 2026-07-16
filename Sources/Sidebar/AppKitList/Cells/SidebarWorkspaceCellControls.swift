import AppKit
import Foundation

/// Label used throughout the workspace cell: borderless, non-editable, with
/// optional word wrap. When wrapping, `preferredMaxLayoutWidth` tracks the
/// laid-out width so intrinsic height stays correct at any column width.
final class SidebarWorkspaceCellLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    var wrapsText = false {
        didSet {
            guard wrapsText != oldValue else { return }
            usesSingleLineMode = !wrapsText
            cell?.usesSingleLineMode = !wrapsText
            cell?.wraps = wrapsText
            lineBreakMode = wrapsText ? .byWordWrapping : .byTruncatingTail
            cell?.truncatesLastVisibleLine = true
            invalidateIntrinsicContentSize()
        }
    }

    override func layout() {
        if wrapsText, preferredMaxLayoutWidth != bounds.width, bounds.width > 0 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }
}

/// Borderless closure-action button. Its title or image is set by callers;
/// the table's `validateProposedFirstResponder` lets it receive clicks.
final class SidebarWorkspaceCellButton: NSButton {
    var onPress: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        title = ""
        target = self
        action = #selector(press)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func press() {
        onPress?()
    }

    /// Reserve layout while invisible (hover-revealed close/delete buttons);
    /// an alpha-0 button must not swallow clicks.
    var isInteractionEnabled = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractionEnabled, alphaValue > 0.01 else { return nil }
        return super.hitTest(point)
    }
}

/// Fixed-square template-symbol view tinted via `contentTintColor`.
final class SidebarWorkspaceCellIconView: NSImageView {
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 0)
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        imageScaling = .scaleProportionallyDown
        widthConstraint.isActive = true
        heightConstraint.isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    private var currentSymbol: String?
    private var currentPointSize: CGFloat = 0
    private var currentWeight: NSFont.Weight = .regular

    func setSymbol(
        _ systemName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor
    ) {
        if currentSymbol != systemName || currentPointSize != pointSize || currentWeight != weight {
            currentSymbol = systemName
            currentPointSize = pointSize
            currentWeight = weight
            image = SidebarWorkspaceCellSymbols.image(systemName, pointSize: pointSize, weight: weight)
            let side = max(1, pointSize)
            // Frame matches CmuxSystemSymbolImage's square raster frame, with
            // headroom for symbols whose natural raster exceeds the point size.
            let frameSide = max(side, image?.size.height ?? side)
            widthConstraint.constant = max(frameSide, image?.size.width ?? side)
            heightConstraint.constant = frameSide
        }
        contentTintColor = color
    }
}

/// Container that top-aligns inside the title row's `.top`-aligned stack while
/// vertically centering its child on the title's first-line optical center
/// (TabItemView's `.sidebarTitleFirstLineCenter` alignment).
final class SidebarWorkspaceCellFirstLineBox: NSView {
    private let child: NSView
    private var topConstraint: NSLayoutConstraint?

    init(child: NSView) {
        self.child = child
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        let top = child.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            top,
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: child.heightAnchor),
        ])
        topConstraint = top
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    /// Positions the child so its center sits `firstLineCenter` below the row
    /// top (clamped at zero — a child taller than the line hugs the top).
    func setFirstLineCenter(_ firstLineCenter: CGFloat, childHeight: CGFloat) {
        topConstraint?.constant = max(0, firstLineCenter - childHeight / 2)
    }
}

/// Capsule progress bar (track + leading-anchored fill), custom-drawn so the
/// fill fraction needs no constraint churn.
final class SidebarWorkspaceCellProgressBarView: NSView {
    var trackColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    var fillColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let clamped = max(0, min(fraction, 1))
        guard clamped > 0 else { return }
        var fillRect = bounds
        fillRect.size.width = bounds.width * clamped
        fillColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }
}

/// Monospaced single-line text that picks the longest candidate fitting the
/// laid-out width (AppKit port of `SidebarDirectoryText` / `ViewThatFits`).
/// Candidates are ordered longest → shortest; the final fallback truncates.
final class SidebarWorkspaceCellDirectoryLabel: NSView {
    private let label = SidebarWorkspaceCellLabel()

    private(set) var candidates: [String] = []
    private var font: NSFont = .systemFont(ofSize: 10)
    private var color: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func update(candidates: [String], font: NSFont, color: NSColor) {
        self.candidates = candidates
        self.font = font
        self.color = color
        label.font = font
        label.textColor = color
        invalidateIntrinsicContentSize()
        needsLayout = true
        chooseCandidate()
    }

    override var intrinsicContentSize: NSSize {
        // Report the shortest candidate's size so the row never grows for a
        // long path; longer candidates appear only when width allows.
        guard let shortest = candidates.last else { return .zero }
        let size = (shortest as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func layout() {
        super.layout()
        chooseCandidate()
    }

    private func chooseCandidate() {
        guard !candidates.isEmpty else {
            label.stringValue = ""
            return
        }
        let available = bounds.width
        var chosen = candidates[candidates.count - 1]
        if available > 0 {
            for candidate in candidates {
                let width = ceil((candidate as NSString).size(withAttributes: [.font: font]).width)
                if width <= available {
                    chosen = candidate
                    break
                }
            }
        }
        if label.stringValue != chosen {
            label.stringValue = chosen
        }
    }
}

/// The cmd-hold shortcut hint chip: rounded material capsule with a rounded
/// semibold monospaced-digit label (AppKit port of `ShortcutHintPill`).
final class SidebarWorkspaceCellHintPillView: NSView {
    private let effectView = NSVisualEffectView()
    private let label = SidebarWorkspaceCellLabel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            return shadow
        }()

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.8
        addSubview(effectView)

        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(text: String, fontSize: CGFloat, emphasis: CGFloat) {
        label.font = SidebarWorkspaceCellFonts.rounded(fontSize, weight: .semibold)
        label.stringValue = text
        label.textColor = .labelColor
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.30 * emphasis).cgColor
    }

    override func layout() {
        super.layout()
        effectView.layer?.cornerRadius = bounds.height / 2
    }
}

/// Reuse pool for variable-count rows inside a vertical stack. Views are
/// created once, appended as arranged subviews, and hidden when unused
/// (NSStackView collapses hidden arranged subviews).
@MainActor
final class SidebarWorkspaceCellRowPool<Row: NSView> {
    private(set) var rows: [Row] = []

    /// Returns exactly `count` visible rows, growing the pool as needed and
    /// hiding the excess.
    func prepare(count: Int, in stack: NSStackView, make: () -> Row) -> [Row] {
        while rows.count < count {
            let row = make()
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= count
        }
        return Array(rows.prefix(count))
    }
}

@MainActor
enum SidebarWorkspaceCellStackFactory {
    static func vertical(spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = alignment
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }

    static func horizontal(spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }
}
