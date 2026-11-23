import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One suggestion: 16 pt icon, then "title – host" on one line with the
/// host dimmed (``shownDetail(_:)``). The one highlighted row
/// (keyboard or mouse, the state machine decides) gets a rounded gray fill
/// concentric with the card (`OmnibarStyle.rowCornerRadius`). The row itself only reports the pointer and clicks.
final class SuggestionRowView: NSView {
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// Pointer inside (true) or leaving (false), at a screen point.
    var onPointer: ((Bool, CGPoint) -> Void)?
    var isHighlighted = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            setAccessibilitySelected(isHighlighted)
            updateFill()
        }
    }
    var leadingIconCenter: CGFloat = 16 { didSet { needsLayout = true } }
    var textLeading: CGFloat = 33 { didSet { needsLayout = true } }

    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
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
        // A density or `browser.omnibar.*` size change while the card is open redraws the row's
        // text and glyph at the new size (the card re-lays out the rows' height).
        density.update { [weak self] in
            guard let self else { return }
            let iconSize = OmnibarStyle.iconSide
            if let iconKind, !showsFavicon { icon.image = NSImage.icon(iconKind, size: iconSize) }
            if showsFavicon, let image = icon.image { image.size = NSSize(width: iconSize, height: iconSize) }
            applyColors()
            needsLayout = true
        }
        density.start()
    }

    private let density = DensityBinding()

    /// Shows `suggestion` in this row, in place (Chromium
    /// `OmniboxResultView::SetMatch`): typing changes the rows' text, it
    /// never tears the card's views down. Touches only what changed.
    /// - Parameter detail: the dimmed text, as the list decides it (``shownDetails(_:)``); nil: this row's own
    ///   (``shownDetail(_:)``).
    func show(_ suggestion: BrowserSuggestion, detail listDetail: String? = nil, force: Bool = false) {
        let shown = listDetail ?? Self.shownDetail(suggestion)
        guard force || suggestion != self.suggestion || shown != detail else { return }
        self.suggestion = suggestion
        let kind: IconName = switch suggestion.kind {
        case .navigate: .browser
        case .search: .browserOmniboxSearch
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
                faviconTask = Task { [weak self] in
                    let image = await source(page)
                    guard !Task.isCancelled, let self, self.faviconURL == page, let image else { return }
                    self.showFavicon(image)
                }
            }
        }
        if kind != iconKind, !showsFavicon {
            iconKind = kind
            icon.image = NSImage.icon(kind, size: OmnibarStyle.iconSide)
        }
        setAccessibilityLabel([suggestion.title, shown].filter { !$0.isEmpty }.joined(separator: ", "))
        guard force || suggestion.title != title || shown != detail else { return }
        title = suggestion.title
        detail = shown
        applyColors()
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The dimmed text after a row's title: a page's host alone, nothing for a search or the typed address (the glyph
    /// and the title say what they are), and
    /// an answer's or an extension's own text. A row names what it opens in as few words as it can (Lawrence
    /// 2026-11-21, "drastically simplify all parts of the UI"): no "Google Search" beside every query, no path.
    static func shownDetail(_ suggestion: BrowserSuggestion) -> String {
        switch suggestion.kind {
        case .search, .navigate: return ""
        case .history, .bookmark, .switchToTab:
            // A page with no title shows its address as the title, the host first: no second host after it.
            let host = BrowserURLDisplay.restingText(for: suggestion.url)
            return suggestion.title.lowercased().hasPrefix(host.lowercased()) ? "" : host
        case .answer, .keyword: return suggestion.detail
        }
    }

    /// Each row's dimmed text, for the list as a whole: ``shownDetail(_:)``, except that page rows that would read the
    /// same (one title, one host: a site's pages often share a title) show their address without the scheme, so each
    /// row still says where it goes.
    static func shownDetails(_ suggestions: [BrowserSuggestion]) -> [String] {
        let details = suggestions.map(shownDetail)
        let lines = zip(suggestions, details).map { "\($0.title)\u{0}\($1)" }
        let repeated = Dictionary(lines.map { ($0, 1) }, uniquingKeysWith: +).filter { $0.value > 1 }
        return suggestions.indices.map { index in
            let suggestion = suggestions[index]
            guard repeated[lines[index]] != nil, !details[index].isEmpty else { return details[index] }
            switch suggestion.kind {
            case .history, .bookmark, .switchToTab: return BrowserURLDisplay.displayText(for: suggestion.url)
            case .search, .navigate, .answer, .keyword: return details[index]
            }
        }
    }

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
        let side = OmnibarStyle.iconSide
        sized.size = NSSize(width: side, height: side)
        showsFavicon = true
        iconKind = nil
        icon.image = sized
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = OmnibarStyle.rowCornerRadius
        // 16 pt at Standard (13 pt glyph size), larger with the bar's text.
        let side = OmnibarStyle.iconSide
        icon.frame = NSRect(x: (leadingIconCenter - side / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        let height = label.intrinsicContentSize.height
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
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onPointer?(true, screenPoint(event)) }
    override func mouseMoved(with event: NSEvent) { onPointer?(true, screenPoint(event)) }
    override func mouseExited(with event: NSEvent) { onPointer?(false, screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { onClick?(event.modifierFlags) }
    override func mouseDown(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool { onClick?([]); return true }

    /// The event's location on screen. A tracking event is delivered to this
    /// row's window, so convert through it; `event.window` is nil when the
    /// event carries no window number (a window that has none yet).
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

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
            icon.contentTintColor = OmnibarStyle.resultsIcon
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
