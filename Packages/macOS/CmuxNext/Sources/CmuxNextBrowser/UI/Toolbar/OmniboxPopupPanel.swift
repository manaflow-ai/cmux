import AppKit
import CmuxNextDesign
import CmuxNextPages

/// The omnibox suggestion card (webviews/src/pages/omnibox-popup): its own borderless child panel
/// of the browser window, flush under the omnibar (above it with the toolbar at the bottom), so it
/// draws above Chromium page windows. It never takes the keys: the field keeps editing while the
/// pointer moves over the rows. The page only draws rows and reports the pointer; the toolbar page
/// decides (`BrowserToolbarWebView` relays both ways).
@MainActor
final class OmniboxPopupPanel {
    /// The pointer is over row `index` (nil: left the rows), in screen points.
    var onHover: ((Int?, CGPoint) -> Void)?
    /// A row was clicked, with Cmd, Shift and Option.
    /// A pick: the row's index and the row the card shows there.
    var onPick: ((Int, BrowserSuggestion?, Bool, Bool, Bool) -> Void)?
    /// Site icons for page rows; nil: kind glyphs only.
    var faviconSource: ((URL) async -> NSImage?)?
    /// Makes the card's React page; tests pass their own.
    var makeWebContent: @MainActor () -> (any BrowserChromeWebContent)? = { BrowserChromeWebHost(.omniboxPopup) }

    private var panel: OmniboxPopupWindow?
    private var content: (any BrowserChromeWebContent)?
    private var rows: [BrowserSuggestion] = []
    /// The row the card shows at `index`, if any.
    func shownRow(_ index: Int) -> BrowserSuggestion? { rows.indices.contains(index) ? rows[index] : nil }
    private var highlighted: Int?
    private var upward = false
    private var bar = NSRect.zero
    /// What the card stays inside, on screen: its pane (and the screen); nil: unbounded.
    private var clip: NSRect?
    /// The card's tallest height in `clip` (`OmniboxCardPlacement.maxCardHeight`): the page
    /// scrolls its rows within it.
    private var maxCardHeight: CGFloat?
    private var revision = 0
    /// The revision that first drew the rows shown now: a hover or pick drawn before it names other rows.
    private var rowsRevision = 0
    /// The card's height the page reported for the newest state; zero before its first report.
    private var cardHeight: CGFloat = 0
    /// Site icons as data URLs, by page URL; bounded (`faviconLimit`), oldest first out.
    private var favicons: [URL: String] = [:]
    private var faviconOrder: [URL] = []
    private var faviconTasks: [URL: Task<Void, Never>] = [:]
    private static let faviconLimit = 128
    /// Space around the card for its shadow: top, right, bottom, left (the side on the bar has none).
    private var margin: (top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat) {
        upward ? (16, 12, 0, 12) : (0, 12, 16, 12)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var rowKinds: [String] { rows.map(\.kind.wire) }

    /// The card's rect on screen (without the shadow margin).
    var cardRectInScreen: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        let frame = panel.frame, m = margin
        return NSRect(x: frame.minX + m.left, y: frame.minY + m.bottom, width: frame.width - m.left - m.right,
                      height: frame.height - m.top - m.bottom)
    }

    /// Shows `rows` under `bar` (the omnibar's rect on screen), or above it when `upward`.
    func show(_ rows: [BrowserSuggestion], highlighted: Int?, upward: Bool, bar: NSRect, clip: NSRect?, in window: NSWindow,
              themeOf view: NSView) {
        guard let content = content ?? makeContent() else { return }
        // Another row count: the estimate until the page reports the new height.
        if rows.count != self.rows.count { cardHeight = 0 }
        if rows != self.rows { rowsRevision = revision + 1 }
        // The field (another web view) cannot point VoiceOver at the card's row: the host reads the
        // newly highlighted row out, as the native card's selection change did.
        if let spoken = Self.announcement(rows: rows, highlighted: highlighted, previous: self.highlighted) {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        self.rows = rows
        self.highlighted = highlighted
        self.upward = upward
        self.bar = bar
        self.clip = clip
        maxCardHeight = OmniboxCardPlacement.maxCardHeight(bar: bar, upward: upward, clip: clip)
        let panel = self.panel ?? makePanel(content)
        panel.adoptThemeScope(of: view)
        panel.applyGlassTheme()
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        fetchFavicons()
        push()
        place()
        if !panel.isVisible { panel.orderFront(nil) }
    }

    /// What VoiceOver reads when the highlight moves to another row: its title and detail; nil when
    /// it did not move or left the rows.
    nonisolated static func announcement(rows: [BrowserSuggestion], highlighted: Int?, previous: Int?) -> String? {
        guard let highlighted, highlighted != previous, rows.indices.contains(highlighted) else { return nil }
        let row = rows[highlighted]
        return row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)"
    }

    /// Keeps an open card on the bar, inside its pane, after the toolbar or its pane moved or
    /// resized, moved to the other edge, or took another density or look.
    func follow(bar: NSRect?, clip: NSRect?, upward: Bool) {
        guard let bar, isVisible else { return }
        let restyled = !(pushedStyle?.isEqual(to: style()) ?? false)
        guard restyled || bar != self.bar || clip != self.clip || upward != self.upward else { return }
        let flipped = upward != self.upward
        self.bar = bar
        self.clip = clip
        self.upward = upward
        let limit = OmniboxCardPlacement.maxCardHeight(bar: bar, upward: upward, clip: clip)
        if limit != maxCardHeight || flipped || restyled {
            maxCardHeight = limit
            push()
        }
        place()
    }

    /// The card's metrics, corner radius and margins as last pushed: a density or look change
    /// pushes them again.
    private var pushedStyle: NSDictionary?

    private func style() -> [String: Any] {
        let m = margin
        return ["metrics": ToolbarRowMetrics.wire(scale: panel?.backingScaleFactor ?? 2, withButtons: false),
                "cornerRadius": ToolbarRowMetrics.cornerRadius, "margin": [m.top, m.right, m.bottom, m.left]]
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        rows = []
        highlighted = nil
        for task in faviconTasks.values { task.cancel() }
        faviconTasks = [:]
    }

    /// The toolbar closes for good: the card's page and panel go.
    func close() {
        dismiss()
        content?.close()
        content = nil
        panel?.close()
        panel = nil
    }

    private func makeContent() -> (any BrowserChromeWebContent)? {
        guard let made = makeWebContent() else { return nil }
        made.onMessage = { [weak self] kind, params in self?.received(kind, params) }
        // The card never takes the keys from the field.
        made.acceptsKeyFocus = { false }
        content = made
        return made
    }

    private func makePanel(_ content: any BrowserChromeWebContent) -> OmniboxPopupWindow {
        let panel = OmniboxPopupWindow()
        panel.host(content.view)
        self.panel = panel
        return panel
    }

    /// The panel's frame: as wide as the bar plus the side margins, the card's height (the page's
    /// report, an estimate before it) plus the shadow margin, flush with the bar.
    private func place() {
        guard let panel else { return }
        let m = margin
        let metrics = OmnibarMetrics.current
        let estimate = CGFloat(rows.count) * (metrics.barHeight + 2) + 4
        let card = OmniboxCardPlacement.cardHeight(cardHeight > 0 ? cardHeight : estimate, limit: maxCardHeight)
        let height = card + m.top + m.bottom
        let y = upward ? bar.maxY - m.bottom : bar.minY + m.top - height
        let frame = NSRect(x: bar.minX - m.left, y: y, width: bar.width + m.left + m.right, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.placeCard(margin: m, upward: upward, cornerRadius: ToolbarRowMetrics.cornerRadius)
    }

    private func push() {
        guard let content else { return }
        revision += 1
        let style = style()
        pushedStyle = style as NSDictionary
        let rows = rows.map { row -> [String: Any] in
            var wire: [String: Any] = ["kind": row.kind.wire, "title": row.title, "detail": row.detail]
            if row.kind.showsSiteIcon, let icon = favicons[row.url] { wire["faviconUrl"] = icon }
            return wire
        }
        content.push(style.merging([
            "revision": revision, "rows": rows, "highlighted": highlighted.map { $0 as Any } ?? NSNull(), "upward": upward,
            "maxHeight": maxCardHeight.map { $0 as Any } ?? NSNull(),
        ]) { $1 })
    }

    private func received(_ kind: String, _ params: [String: Any]) {
        switch kind {
        case "command":
            // A row index means the rows the page drew: rows shown since (another query, another tab
            // after the card closed) or a closed card take no hover or pick.
            guard isVisible, let drawn = OmniboxPopupCommand.revision(params), drawn >= rowsRevision else { return }
            switch OmniboxPopupCommand(wire: params) {
            case .hover(let index, let pointer): onHover?(index, pointer)
            case .pick(let index, let meta, let shift, let alt):
                onPick?(index, shownRow(index), meta, shift, alt)
            case nil: break
            }
        case "size":
            // The card's height for the newest state (margins excluded).
            guard let height = (params["height"] as? NSNumber)?.doubleValue, height > 0,
                  (params["revision"] as? NSNumber)?.intValue == revision else { return }
            let next = ceil(height)
            guard next != cardHeight else { return }
            cardHeight = next
            place()
        default:
            break
        }
    }

    // MARK: Site icons

    /// Fetches the icons of the shown page rows not fetched yet; each arrival pushes the rows again.
    private func fetchFavicons() {
        guard let faviconSource else { return }
        for row in rows where row.kind.showsSiteIcon && favicons[row.url] == nil && faviconTasks[row.url] == nil {
            let url = row.url
            faviconTasks[url] = Task { [weak self] in
                let image = await faviconSource(url)
                guard !Task.isCancelled, let self else { return }
                self.faviconTasks[url] = nil
                guard let data = image.flatMap(Self.pngData) else { return }
                self.remember(url, "data:image/png;base64," + data.base64EncodedString())
                if self.isVisible, self.rows.contains(where: { $0.url == url }) { self.push() }
            }
        }
    }

    private func remember(_ url: URL, _ icon: String) {
        if favicons[url] == nil { faviconOrder.append(url) }
        favicons[url] = icon
        while faviconOrder.count > Self.faviconLimit { favicons[faviconOrder.removeFirst()] = nil }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// Where the card may reach (AddressBarView's card was clipped to its pane, `cardPane`): flush on
/// the bar's side and no further than the pane's (and the screen's) far edge, so in a short split
/// it never covers the neighboring pane or leaves the window; the rows scroll within that height.
/// Screen coordinates, y up.
nonisolated enum OmniboxCardPlacement {
    /// The least card height kept even when the pane leaves no room: one row and the card's ends.
    static let minimumHeight: CGFloat = 40

    /// The card's tallest height under (`upward`: above) `bar` inside `clip`; nil without a clip.
    static func maxCardHeight(bar: NSRect, upward: Bool, clip: NSRect?) -> CGFloat? {
        guard let clip, !clip.isNull, !clip.isEmpty else { return nil }
        let room = upward ? clip.maxY - bar.maxY : bar.minY - clip.minY
        return max(minimumHeight, floor(room))
    }

    /// `height` within `limit` (none: as it is).
    static func cardHeight(_ height: CGFloat, limit: CGFloat?) -> CGFloat {
        limit.map { min(height, $0) } ?? height
    }

    /// The pane `bar` belongs to on screen, within the screen's visible frame: what the card stays inside.
    static func clip(pane: NSRect, screen: NSRect?) -> NSRect {
        guard let screen else { return pane }
        let both = pane.intersection(screen)
        return both.isNull ? pane : both
    }
}

/// The card's window: a popup panel that never becomes key, so the omnibar keeps the keys, and
/// that acts on the first click (the page's web view accepts it). The card is the shared overlay
/// glass, drawn here under the page; the page draws only the rows over it (and the shadow in the
/// margin around it).
final class OmniboxPopupWindow: NativePopupPanel {
    /// Clips the glass's corners on the bar's side, so the card meets the bar square.
    private let clip = NSView()
    private let glass = Glass.makeOverlayPanel(cornerRadius: ToolbarRowMetrics.cornerRadius)
    /// The card in the content view; around it is only the shadow margin.
    private(set) var cardRect = NSRect.zero

    init() {
        super.init(identifier: "cmux.omniboxPopup")
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = true
        clip.addSubview(glass)
        contentView?.addSubview(clip)
    }

    override var canBecomeKey: Bool { false }

    /// A click in the shadow margin is the window's below: the margin overlaps the toolbar's buttons
    /// beside the bar (Reload, the extensions), which the card must not cover.
    override func sendEvent(_ event: NSEvent) {
        if let parent, let forwarded = Self.forwarded(event, outside: cardRect, from: self, to: parent) {
            parent.sendEvent(forwarded)
            return
        }
        super.sendEvent(event)
    }

    /// `event` moved to `target` when it is a mouse press, drag or release outside `card` (in
    /// `source`'s content view); nil keeps it in `source`.
    static func forwarded(_ event: NSEvent, outside card: NSRect, from source: NSWindow, to target: NSWindow) -> NSEvent? {
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                             .otherMouseDown, .otherMouseUp]
        guard mouse.contains(event.type), let content = source.contentView,
              !card.contains(content.convert(event.locationInWindow, from: nil)) else { return nil }
        let screen = source.convertPoint(toScreen: event.locationInWindow)
        return NSEvent.mouseEvent(with: event.type, location: target.convertPoint(fromScreen: screen), modifierFlags: event.modifierFlags,
                                  timestamp: event.timestamp, windowNumber: target.windowNumber, context: nil,
                                  eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure)
    }

    /// Puts the card's page over the glass, filling the panel.
    func host(_ view: NSView) {
        guard let host = contentView else { return }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = host.bounds
        host.addSubview(view, positioned: .above, relativeTo: clip)
    }

    /// The glass at the card's rect: inside the shadow margin, its corners on the bar's side
    /// clipped square (above the bar when `upward`).
    func placeCard(margin m: (top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat), upward: Bool, cornerRadius: CGFloat) {
        let size = contentView?.bounds.size ?? frame.size
        let card = NSRect(x: m.left, y: m.bottom, width: max(0, size.width - m.left - m.right),
                          height: max(0, size.height - m.top - m.bottom))
        cardRect = card
        if clip.frame != card { clip.frame = card }
        glass.cornerRadius = cornerRadius
        let rect = NSRect(x: 0, y: upward ? -cornerRadius : 0, width: card.width, height: card.height + cornerRadius)
        if glass.frame != rect { glass.frame = rect }
    }

    /// The glass tint of the theme scope the panel adopted (the omnibar's).
    func applyGlassTheme() {
        contentView?.performWithTheme { glass.applyTheme() }
    }
}
