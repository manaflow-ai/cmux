import AppKit
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextInput

/// One suggestion: 16 pt icon, then "title – detail" on one line with the
/// detail dimmed ("query - Engine Search"). The one highlighted row
/// (keyboard or mouse, the state machine decides) gets a rounded gray fill
/// concentric with the card (`OmnibarStyle.rowCornerRadius`). The row itself only reports the pointer and clicks.
final class SuggestionRowView: NSView {
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// The card's one hover consumer (``OmniboxSuggestionPanel``): the row's moves, enters and exits go
    /// to it and its delivery reports the row under the latest point (or none), at most twice a frame
    /// for the whole card with feature `pointerFrameHover` (Chromium's rAF-aligned moves,
    /// main_thread_event_queue.cc; boundary events from those moves, boundary_event_dispatcher.cc).
    /// A press flushes it first; the card flushes it when the pointer leaves the card.
    weak var frameInputHover: PointerFrameHover?
    var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            setAccessibilitySelected(isHighlighted)
            updateFill()
        }
    }
    var leadingIconCenter: CGFloat = 16 { didSet { if leadingIconCenter != oldValue { needsLayout = true } } }
    var textLeading: CGFloat = 33 { didSet { if textLeading != oldValue { needsLayout = true } } }
    /// The highlight's corner, concentric with the card's (`OmnibarStyle.rowCornerRadius`, which follows
    /// the look live), set at each placement like the card's: a new radius reshapes the layer, no layout.
    var cornerRadius: CGFloat = 0 { didSet { if cornerRadius != oldValue { layer?.cornerRadius = cornerRadius } } }
    /// The label height the last layout framed: new text of the same height needs no layout, the
    /// label repaints itself.
    private var laidOutLabelHeight: CGFloat?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var title = ""
    private var detail = ""
    private var iconKind: IconName?
    /// The match shown now.
    private(set) var suggestion: BrowserSuggestion
    /// The site icon of a page row (Chrome draws each match's favicon), from
    /// the address bar (`AddressBarView.rowFavicon`). Nil: kind glyphs only.
    var faviconSource: ((URL) async -> NSImage?)?
    /// The page whose icon shows (or loads) now, and the load.
    private var faviconURL: URL?
    private(set) var faviconTask: Task<Void, Never>?
    /// True while the row draws a site icon instead of its kind glyph.
    private(set) var showsFavicon = false

    init(suggestion: BrowserSuggestion, faviconSource: ((URL) async -> NSImage?)? = nil) {
        self.suggestion = suggestion
        self.faviconSource = faviconSource
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(icon)
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilitySelected(false)
        show(suggestion, force: true)
    }

    /// Shows `suggestion` in this row, in place (Chromium
    /// `OmniboxResultView::SetMatch`): typing changes the rows' text, it
    /// never tears the card's views down. Touches only what changed.
    func show(_ suggestion: BrowserSuggestion, force: Bool = false) {
        guard force || suggestion != self.suggestion else { return }
        self.suggestion = suggestion
        let kind: IconName = switch suggestion.kind {
        case .navigate: .browser
        case .search: .search
        case .history: .history
        case .bookmark: .bookmark
        case .keyword: .extension
        case .switchToTab: .omnibarSwitchtab
        case .answer: .omnibarAnswer
        }
        let page = Self.showsSiteIcon(suggestion) ? suggestion.url : nil
        if page != faviconURL {
            // Another page: its glyph until its icon arrives.
            faviconURL = page
            faviconTask?.cancel()
            faviconTask = nil
            showsFavicon = false
            iconKind = nil
            if let page, let source = faviconSource {
                // task-owner: this row; cancelled when the row shows another page.
                // main-hop-allow: the source is the tab's main-actor async favicon fetch (the request runs in the page's network stack); this task only starts it and shows the icon
                faviconTask = Task { [weak self] in
                    let image = await source(page)
                    guard !Task.isCancelled, let self, self.faviconURL == page, let image else { return }
                    self.showFavicon(image)
                }
            }
        }
        if kind != iconKind, !showsFavicon {
            iconKind = kind
            icon.image = NSImage.icon(kind, size: .iconRowSize(forLabelPointSize: OmnibarStyle.iconPointSize))
        }
        setAccessibilityLabel([suggestion.title, suggestion.detail].filter { !$0.isEmpty }.joined(separator: ", "))
        guard force || suggestion.title != title || suggestion.detail != detail else { return }
        title = suggestion.title
        detail = suggestion.detail
        applyColors()
        // A typed character changes the text, not the frames: the label keeps its width and line.
        if label.intrinsicContentSize.height != laidOutLabelHeight { needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rows that name a known web page show its site icon: history,
    /// bookmarks and open tabs. The typed address keeps its globe (Chrome
    /// too), so a half-typed host is never fetched; searches, answers and
    /// extension rows keep their glyph.
    static func showsSiteIcon(_ suggestion: BrowserSuggestion) -> Bool {
        guard [.history, .bookmark, .switchToTab].contains(suggestion.kind),
              let scheme = suggestion.url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func showFavicon(_ image: NSImage) {
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 16, height: 16)
        showsFavicon = true
        iconKind = nil
        icon.image = sized
    }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        icon.frame = NSRect(x: (leadingIconCenter - side / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        let height = label.intrinsicContentSize.height
        laidOutLabelHeight = height
        label.frame = NSRect(
            x: textLeading,
            y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - textLeading - OmnibarStyle.trailingPadding),
            height: height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeForHover, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // Crossing into or out of a row is a position like a move: the card's consumer coalesces it with the
    // moves around it, so a sweep across the rows reports at most twice a frame. A press is discrete: the
    // pending move lands first (`ShouldFlushQueue`).
    override func mouseEntered(with event: NSEvent) { frameInputHover?.crossed(event) }
    override func mouseMoved(with event: NSEvent) { frameInputHover?.moved(event) }
    override func mouseExited(with event: NSEvent) { frameInputHover?.crossed(event) }
    override func mouseUp(with event: NSEvent) { onClick?(event.modifierFlags) }
    override func mouseDown(with event: NSEvent) { frameInputHover?.flush() }
    override func accessibilityPerformPress() -> Bool { onClick?([]); return true }

    // visibility-walk-allow: a row exists only in the open suggestion card, which shows while the bar edits; nothing hidden to defer
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            icon.contentTintColor = OmnibarStyle.textSecondary
            let text = NSMutableAttributedString(string: title, attributes: [
                .font: OmnibarStyle.font,
                .foregroundColor: OmnibarStyle.textPrimary,
            ])
            if !detail.isEmpty {
                text.append(NSAttributedString(string: " – " + detail, attributes: [
                    .font: OmnibarStyle.rowDetailFont,
                    .foregroundColor: OmnibarStyle.textSecondary,
                ]))
            }
            label.attributedStringValue = text
        }
        updateFill()
    }

    private func updateFill() {
        performWithTheme {
            layer?.backgroundColor = (isHighlighted ? OmnibarStyle.rowSelectedFill : .clear).cgColor
        }
    }
}
