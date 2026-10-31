import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The table, with no focus ring and no type select (the list is read, not edited).
final class FeedTableView: NSTableView {
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }
}

/// A row's ground: hover and selection fills, and the click that selects (twice: opens) its item.
final class FeedTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.feed.rowView")
    var onClick: ((FeedRowEntry, Int) -> Void)?
    private(set) var entry: FeedRowEntry?
    private var colors = ReportsBasketColors()
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    func show(_ entry: FeedRowEntry, colors: ReportsBasketColors) {
        let redraw = entry != self.entry || colors != self.colors
        self.entry = entry
        self.colors = colors
        if case let .row(content) = entry {
            setAccessibilityLabel(content.accessibilityLabel)
            setAccessibilityIdentifier("cmux.feed.row")
            themedToolTip = nil
        } else {
            setAccessibilityLabel(nil)
        }
        if redraw { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard let entry, case .row = entry else { return super.mouseDown(with: event) }
        onClick?(entry, event.clickCount)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard case let .row(content) = entry else { return }
        let fill: NSColor? = content.isSelected ? colors.selection : (hovering ? colors.hover : nil)
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

/// "Needs you 3": an Inbox section title.
final class FeedHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.feed.header")
    private let title = FeedRowCell.label(size: TypeScale.caption, weight: TypeScale.emphasis)
    private let count = FeedRowCell.label(size: TypeScale.caption)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        addSubview(title)
        addSubview(count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(title text: String, count value: Int, colors: ReportsBasketColors) {
        title.stringValue = text
        count.stringValue = "\(value)"
        title.textColor = colors.secondary
        count.textColor = colors.tertiary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = ceil(title.intrinsicContentSize.width)
        let y = bounds.height - TypeScale.captionLineHeight - 6
        title.frame = NSRect(x: 17, y: y, width: min(width, bounds.width - 60), height: TypeScale.captionLineHeight)
        count.frame = NSRect(x: title.frame.maxX + 6, y: y, width: 40, height: TypeScale.captionLineHeight)
    }

    override var isFlipped: Bool { false }
}

/// One event: what happened and when on the first line, one line of detail, then who and where.
///
///     ● ⌘ Finished: updated FeedModel.swift and 3 tests                 3m
///         Ran swift test --filter FeedModelTests: 42 passed.
///         Claude Code · api-server › Fix login redirect · ×2
///
/// Frames are set by hand from the fixed type scale, so a row that scrolls in measures nothing.
final class FeedRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.feed.cell")
    private(set) var content: FeedRowContent?
    let headline = FeedRowCell.label(size: TypeScale.body)
    let time = FeedRowCell.label(size: TypeScale.caption)
    let detail = FeedRowCell.label(size: TypeScale.detail)
    let meta = FeedRowCell.label(size: TypeScale.caption)
    private let glyph = NSImageView()
    private let dot = NSView()
    private let local = NSImageView()
    private var icon: IconName?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        glyph.imageScaling = .scaleProportionallyDown
        local.image = NSImage.icon(.machineLocal, size: .iconRowSize(forLabelPointSize: TypeScale.caption))
        local.image?.isTemplate = true
        time.alignment = .right
        for view in [dot, glyph, headline, time, detail, meta, local] { addSubview(view) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func label(size: CGFloat, weight: NSFont.Weight = TypeScale.regular) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        label.setAccessibilityElement(false)
        return label
    }

    func show(_ content: FeedRowContent, colors: ReportsBasketColors, now: Date, times: FeedRelativeTime.Formatter) {
        self.content = content
        headline.stringValue = content.headline
        headline.font = .systemFont(ofSize: TypeScale.body, weight: content.isUnread ? TypeScale.emphasis : TypeScale.regular)
        headline.textColor = content.isUnread || content.isOpenRequest ? colors.primary : colors.secondary
        time.stringValue = times.string(content.createdAt, now: now)
        time.themedToolTip = content.whenFull
        time.textColor = colors.tertiary
        detail.stringValue = content.detail
        detail.font = content.detailIsCode
            ? .monospacedSystemFont(ofSize: TypeScale.detail, weight: TypeScale.regular)
            : .systemFont(ofSize: TypeScale.detail, weight: TypeScale.regular)
        detail.textColor = colors.secondary
        detail.isHidden = content.detail.isEmpty
        var line = content.meta
        if content.count > 1 { line += line.isEmpty ? "×\(content.count)" : " · ×\(content.count)" }
        if content.threadCount > 1 {
            let thread = FeedStrings.threadCount(content.threadCount)
            line += line.isEmpty ? thread : " · \(thread)"
        }
        meta.stringValue = line
        meta.textColor = colors.tertiary
        local.isHidden = !content.isLocal
        local.contentTintColor = colors.tertiary
        local.themedToolTip = FeedStrings.thisMac
        if icon != content.icon {
            icon = content.icon
            glyph.image = NSImage.icon(content.icon, size: .iconRowSize(forLabelPointSize: TypeScale.body))
            glyph.image?.isTemplate = true
        }
        glyph.contentTintColor = content.isUrgent ? colors.attention
            : content.isOpenRequest ? colors.primary : content.isDimmed ? colors.tertiary : colors.secondary
        dot.layer?.backgroundColor = (content.isUnread ? colors.primary : .clear).cgColor
        alphaValue = content.isPending ? 0.55 : 1
        needsLayout = true
    }

    /// The relative time against `now`; redrawn only when its text changed.
    func showTime(now: Date, times: FeedRelativeTime.Formatter) {
        guard let content else { return }
        let text = times.string(content.createdAt, now: now)
        if time.stringValue != text {
            time.stringValue = text
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    /// Clicks go to the row (its labels take none), which selects or opens the item.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        let left: CGFloat = 40, right: CGFloat = 14, top: CGFloat = 7
        let width = bounds.width - left - right
        // Measured from the text: a one-line truncating label's intrinsic width follows its frame.
        let timeText = time.stringValue as NSString
        let timeWidth = min(ceil(timeText.size(withAttributes: [.font: time.font ?? NSFont.systemFont(ofSize: TypeScale.caption)]).width) + 4, 64)
        dot.frame = NSRect(x: 9, y: top + (TypeScale.bodyLineHeight - 6) / 2, width: 6, height: 6)
        let side = CGFloat.iconRowSize(forLabelPointSize: TypeScale.body)
        glyph.frame = NSRect(x: 19, y: top + (TypeScale.bodyLineHeight - side) / 2, width: side, height: side)
        headline.frame = NSRect(x: left, y: top, width: max(0, width - timeWidth - 6), height: TypeScale.bodyLineHeight)
        // A clipped headline reads in full as the row's themed tooltip, as a clipped sidebar title does
        // (WorkspaceRowView.updateCalmTitleTip). Set on the cell, not the label: a tooltip that repeats
        // its own label's text is dropped (TooltipTracker.repeatsVisibleLabel).
        let headlineWidth = (headline.stringValue as NSString).size(withAttributes: [.font: headline.font ?? NSFont.systemFont(ofSize: TypeScale.body)]).width
        let tip = ceil(headlineWidth) > headline.frame.width + 0.5 ? headline.stringValue : nil
        if themedToolTip != tip { themedToolTip = tip }
        time.frame = NSRect(x: bounds.width - right - timeWidth, y: top + 2, width: timeWidth, height: TypeScale.captionLineHeight)
        var y = top + TypeScale.bodyLineHeight + 2
        if !detail.isHidden {
            detail.frame = NSRect(x: left, y: y, width: width, height: TypeScale.detailLineHeight)
            y += TypeScale.detailLineHeight + 2
        }
        let localSide: CGFloat = local.isHidden ? 0 : CGFloat.iconRowSize(forLabelPointSize: TypeScale.caption)
        meta.frame = NSRect(x: left, y: y, width: max(0, width - localSide - 4), height: TypeScale.captionLineHeight)
        let metaText = meta.stringValue as NSString
        let metaWidth = min(ceil(metaText.size(withAttributes: [.font: meta.font ?? NSFont.systemFont(ofSize: TypeScale.caption)]).width), meta.frame.width)
        local.frame = NSRect(x: left + metaWidth + 4, y: y + (TypeScale.captionLineHeight - localSide) / 2, width: localSide, height: localSide)
    }
}
