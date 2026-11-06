public import AppKit
public import CmuxNextDesign
import CmuxNextIcons
import Observation

/// How the pinned Needs you section draws (`feed.needsYouStyle`, Debug Settings > Feed). Rows is
/// the default; the others are its gallery variants, switched live.
public nonisolated enum FeedNeedsYouStyle: String, Sendable, CaseIterable, TunableChoice {
    /// One line per request: what it is, who asked, and its one-click answers at the end.
    case rows
    /// The Feed list's own request cards (what it asks, then its answers under it).
    case cards
    /// One line for all of them: the count and the first request; a click opens it.
    case bar

    public var tunableTitle: String {
        switch self {
        case .rows: "Rows (answers at the end)"
        case .cards: "Cards (the Feed's request cards)"
        case .bar: "One line (count and first request)"
        }
    }
}

extension FeedModel {
    /// What waits on the person: the Feed's open requests, the items and the order its list pins at
    /// its top (``listSections``), read from this model (no second store).
    public var needsYou: [FeedItem] { listSections.requests }
}

/// The Feed's open requests as a pinned section (Chief Home's Needs you), in AppKit: each request
/// says what it is and who asked (``FeedRowContent``, the Feed row's own words); a click on it opens
/// its source (``onOpen``); the answers the Feed's own row offers in one click are the Feed's
/// (``FeedAnswerHost``, its `FeedAnswerControls`), so they answer through ``FeedModel/answer(_:_:)``.
/// Past ``limit`` requests the rest are counted, and the count opens the Feed (``onShowAll``). It
/// draws nothing when nothing waits; the host removes it then.
///
/// It follows the model with one `withObservationTracking` read of what it shows, re-armed after
/// each change only while it is in a window (stop condition: leaving the window), and owns no timer.
public final class FeedNeedsYouView: NSView {
    public let model: FeedModel
    /// The look; nil follows ``FeedTunables/needsYouStyle``.
    public let style: FeedNeedsYouStyle?
    /// The most requests listed; the rest are counted.
    public let limit: Int
    /// A click on a request (not on one of its answers): the host opens its source.
    public var onOpen: (FeedItem) -> Void = { _ in }
    /// A click on the count of the requests not listed: the host opens the Feed.
    public var onShowAll: () -> Void = {}
    /// The section's height changed (a request came or went, an answer form opened).
    public var onHeightChange: () -> Void = {}

    private var colors = FeedColors()
    private let title = FeedRowCell.label(size: TypeScale.caption, weight: TypeScale.emphasis)
    private let count = FeedRowCell.label(size: TypeScale.caption)
    private let more = NSButton(title: "", target: nil, action: nil)
    private let bar = FeedNeedsYouRowView()
    private var rows: [String: FeedNeedsYouRowView] = [:]
    private var order: [String] = []
    private var shownStyle: FeedNeedsYouStyle = .rows
    private var height: CGFloat = 0
    private var tracking = false

    static let padding: CGFloat = 6
    static let headerHeight: CGFloat = 22
    static let rowHeight: CGFloat = 40

    public init(model: FeedModel, style: FeedNeedsYouStyle? = nil, limit: Int = 3) {
        self.model = model
        self.style = style
        self.limit = max(1, limit)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Metrics.surfaceCornerRadius
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.home.needsYou")
        more.isBordered = false
        more.target = self
        more.action = #selector(showAllClicked)
        more.setAccessibilityIdentifier("cmux.home.needsYou.more")
        bar.onOpen = { [weak self] id in self?.barClicked(id) }
        for view in [title, count, more, bar] { addSubview(view) }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }

    /// The requests listed, in the Feed's order.
    public var shownIDs: [String] { Self.split(model.needsYou, limit: limit).shown.map(\.id) }
    /// The requests past ``limit``, counted in the header.
    public var moreCount: Int { Self.split(model.needsYou, limit: limit).more }
    /// Nothing waits: the section draws nothing.
    public var isEmpty: Bool { model.needsYou.isEmpty }
    /// The height its content needs.
    public var preferredHeight: CGFloat { height }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    /// The requests listed and how many more there are.
    nonisolated static func split(_ requests: [FeedItem], limit: Int) -> (shown: [FeedItem], more: Int) {
        (Array(requests.prefix(limit)), max(0, requests.count - limit))
    }

    /// The answers a request's row offers in place: the ones the Feed row answers with a click.
    /// A question or a choice needs typing or picking: its row opens it instead.
    nonisolated static func answersInline(_ item: FeedItem) -> Bool {
        switch item.prompt {
        case .notice, .question, .choice: false
        case .approve, .confirm, .signIn, .passkey, .review, .handoff, .file, .input, .custom: true
        }
    }

    // MARK: - Following the model

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveColors()
        if window != nil, !tracking { follow() }
    }

    /// One observation of what the section shows; re-armed after each change while in a window.
    private func follow() {
        tracking = true
        withObservationTracking {
            reload()
        } onChange: { [weak self] in
            // task-owner: one main-actor hop per model change; re-arms only while the view is in a window
            Task { @MainActor [weak self] in
                guard let self else { return }
                tracking = false
                if window != nil { follow() } else { reload() }
            }
        }
    }

    /// Builds the header and the rows from the model (rows keep their views by item id).
    private func reload() {
        let requests = model.needsYou
        let style = style ?? FeedTunables.needsYouStyle.value
        let (shown, more) = Self.split(requests, limit: limit)
        _ = model.now
        let ids = style == .bar ? [] : shown.map(\.id)
        for (id, row) in rows where !ids.contains(id) || style != shownStyle {
            row.removeFromSuperview()
            rows[id] = nil
        }
        shownStyle = style
        order = ids
        for item in style == .bar ? [] : shown {
            let row: FeedNeedsYouRowView
            if let kept = rows[item.id] {
                row = kept
            } else {
                row = FeedNeedsYouRowView()
                row.onOpen = { [weak self] id in self?.rowClicked(id) }
                row.onResize = { [weak self] in self?.relayout() }
                addSubview(row)
                rows[item.id] = row
            }
            row.show(item, model: model, colors: colors, style: style)
        }
        title.stringValue = FeedStrings.needsYou
        count.stringValue = "\(requests.count)"
        self.more.attributedTitle = NSAttributedString(string: more > 0 ? FeedStrings.needsYouMore(more) : "", attributes: [
            .font: NSFont.systemFont(ofSize: TypeScale.caption, weight: TypeScale.regular), .foregroundColor: colors.basket.secondary,
        ])
        self.more.isHidden = more == 0 || style == .bar
        title.isHidden = style == .bar || requests.isEmpty
        count.isHidden = title.isHidden
        bar.isHidden = style != .bar || requests.isEmpty
        if style == .bar, let first = requests.first { bar.showBar(first, count: requests.count, colors: colors) }
        isHidden = requests.isEmpty
        setAccessibilityLabel("\(FeedStrings.needsYou), \(requests.count)")
        relayout()
    }

    /// Measures the content and lays it out; tells the host when the height changed.
    private func relayout() {
        let style = shownStyle
        var next: CGFloat
        if isEmpty {
            next = 0
        } else if style == .bar {
            next = Self.rowHeight
        } else {
            next = Self.padding * 2 + Self.headerHeight
            for id in order { next += rows[id]?.preferredHeight(width: max(0, bounds.width - 2 * Self.padding)) ?? Self.rowHeight }
        }
        needsLayout = true
        if next != height {
            height = next
            invalidateIntrinsicContentSize()
            onHeightChange()
        }
    }

    public override func layout() {
        super.layout()
        let inset = Self.padding, width = max(0, bounds.width - 2 * inset)
        if shownStyle == .bar {
            bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            return
        }
        let titleWidth = ceil(title.intrinsicContentSize.width)
        let lineY = inset + (Self.headerHeight - TypeScale.captionLineHeight) / 2
        title.frame = NSRect(x: inset + 8, y: lineY, width: min(titleWidth, width / 2), height: TypeScale.captionLineHeight)
        count.frame = NSRect(x: title.frame.maxX + 6, y: lineY, width: 40, height: TypeScale.captionLineHeight)
        let moreWidth = ceil(more.intrinsicContentSize.width) + 8
        more.frame = NSRect(x: bounds.width - inset - moreWidth, y: inset, width: moreWidth, height: Self.headerHeight)
        var y = inset + Self.headerHeight
        for id in order {
            guard let row = rows[id] else { continue }
            let h = row.preferredHeight(width: width)
            row.frame = NSRect(x: inset, y: y, width: width, height: h)
            y += h
        }
    }

    // MARK: - Look

    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() { resolveColors() }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
    }

    private func resolveColors() {
        let resolved = performWithTheme { FeedColors.resolved(background: Palette.elevatedBackground) }
        let (fill, border, shadow) = performWithTheme { (Palette.elevatedBackground, Palette.separator, Palette.shadow) }
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = resolved.borders ? 1 : 0
        layer?.borderColor = border.cgColor
        layer?.shadowColor = shadow.cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        title.textColor = resolved.basket.secondary
        count.textColor = resolved.basket.tertiary
        guard resolved != colors else { return }
        colors = resolved
        reload()
    }

    // MARK: - Clicks

    @objc private func showAllClicked() { onShowAll() }

    private func rowClicked(_ id: String) {
        if let item = model.item(id) { onOpen(item) }
    }

    /// The bar opens its only request, or the Feed when there are more.
    private func barClicked(_ id: String) {
        let requests = model.needsYou
        if requests.count == 1, let item = requests.first { onOpen(item) } else { onShowAll() }
    }
}

/// One request: what it is and who asked (a click there opens its source, and only that part
/// lights on hover), then its one-click answers; or, in the cards style, the Feed's request card.
final class FeedNeedsYouRowView: NSView {
    var onOpen: (String) -> Void = { _ in }
    var onResize: () -> Void = {}
    private let opener = FeedNeedsYouOpener()
    private let glyph = NSImageView()
    private let headline = FeedRowCell.label(size: TypeScale.body, weight: TypeScale.emphasis)
    private let meta = FeedRowCell.label(size: TypeScale.caption)
    private var answers: NSView?
    private var card: NSView?
    private var id: String?
    private var icon: IconName?

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.imageScaling = .scaleProportionallyDown
        for view in [glyph, headline, meta] { opener.addSubview(view) }
        addSubview(opener)
        opener.onClick = { [weak self] in if let id = self?.id { self?.onOpen(id) } }
        opener.setAccessibilityIdentifier("cmux.home.needsYou.row")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func show(_ item: FeedItem, model: FeedModel, colors: FeedColors, style: FeedNeedsYouStyle) {
        id = item.id
        if style == .cards {
            opener.isHidden = true
            answers?.removeFromSuperview()
            answers = nil
            let view = FeedAnswerHost.card(item: item, model: model, colors: colors, reusing: card, onResize: { [weak self] in self?.onResize() })
            if view !== card { card?.removeFromSuperview(); addSubview(view); card = view }
            needsLayout = true
            return
        }
        card?.removeFromSuperview()
        card = nil
        opener.isHidden = false
        let content = FeedRowContent(item: item, place: model.place?(item))
        headline.stringValue = content.headline
        headline.textColor = colors.basket.primary
        let who = content.meta.isEmpty ? item.poster.displayLabel : content.meta
        meta.stringValue = "\(who) · \(FeedRelativeTime.string(item.createdAt, now: model.now))"
        meta.textColor = colors.basket.tertiary
        if icon != content.icon {
            icon = content.icon
            glyph.image = NSImage.icon(content.icon, size: .iconRowSize(forLabelPointSize: TypeScale.body))
            glyph.image?.isTemplate = true
        }
        glyph.contentTintColor = content.isUrgent ? colors.basket.attention : colors.basket.primary
        opener.hoverFill = colors.basket.hover
        opener.setAccessibilityLabel(content.accessibilityLabel)
        if FeedNeedsYouView.answersInline(item) {
            let view = FeedAnswerHost.answers(item: item, model: model, colors: colors, reusing: answers,
                                              onResize: { [weak self] in self?.needsLayout = true })
            if view !== answers { answers?.removeFromSuperview(); addSubview(view); answers = view }
        } else {
            answers?.removeFromSuperview()
            answers = nil
        }
        alphaValue = model.isPending(item.id) ? 0.55 : 1
        needsLayout = true
    }

    /// The one-line bar: "Needs you 3 · Allow make build?".
    func showBar(_ first: FeedItem, count: Int, colors: FeedColors) {
        id = first.id
        card?.removeFromSuperview()
        card = nil
        answers?.removeFromSuperview()
        answers = nil
        let content = FeedRowContent(item: first, place: nil)
        headline.stringValue = "\(FeedStrings.needsYou) \(count)"
        headline.textColor = colors.basket.primary
        meta.stringValue = content.headline
        meta.textColor = colors.basket.secondary
        icon = content.icon
        glyph.image = NSImage.icon(content.icon, size: .iconRowSize(forLabelPointSize: TypeScale.body))
        glyph.image?.isTemplate = true
        glyph.contentTintColor = colors.basket.primary
        opener.hoverFill = colors.basket.hover
        opener.setAccessibilityLabel("\(FeedStrings.needsYou) \(count): \(content.headline)")
        opener.setAccessibilityIdentifier("cmux.home.needsYou.bar")
        needsLayout = true
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        guard let card else { return FeedNeedsYouView.rowHeight }
        return ceil(card.fittingSize.height)
    }

    override func layout() {
        super.layout()
        if let card {
            card.frame = bounds
            return
        }
        let answerSize = answers?.fittingSize ?? .zero
        if let answers {
            answers.frame = NSRect(x: bounds.width - answerSize.width - 4, y: ((bounds.height - answerSize.height) / 2).rounded(),
                                   width: answerSize.width, height: answerSize.height)
        }
        let openerWidth = max(0, bounds.width - (answers == nil ? 0 : answerSize.width + 12))
        opener.frame = NSRect(x: 0, y: 2, width: openerWidth, height: bounds.height - 4)
        let side = CGFloat.iconRowSize(forLabelPointSize: TypeScale.body)
        let textX: CGFloat = 32, textWidth = max(0, openerWidth - textX - 8)
        if headline.stringValue.isEmpty == false, meta.stringValue.isEmpty == false {
            let top = (opener.bounds.height - TypeScale.bodyLineHeight - TypeScale.captionLineHeight) / 2
            headline.frame = NSRect(x: textX, y: top, width: textWidth, height: TypeScale.bodyLineHeight)
            meta.frame = NSRect(x: textX, y: top + TypeScale.bodyLineHeight, width: textWidth, height: TypeScale.captionLineHeight)
        }
        glyph.frame = NSRect(x: 8, y: (opener.bounds.height - side) / 2, width: side, height: side)
    }
}

/// The open part of a request's row: its hover fill covers only itself, and a click opens.
final class FeedNeedsYouOpener: NSView {
    var onClick: () -> Void = {}
    var hoverFill: NSColor = .clear { didSet { needsDisplay = true } }
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Its labels take no clicks: the whole part is one target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        hoverFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.insetCornerRadius, yRadius: Metrics.insetCornerRadius).fill()
    }
}
