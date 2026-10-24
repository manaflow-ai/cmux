public import AppKit

/// A page's menu drawn past its window's edge (cx-6k6cg). A page menu that has no room above or
/// below its anchor inside the web view hands its rows here: they show in a child panel of the
/// window (``ContentChildPanel``, the ``Glass/makeOverlayPanel`` surface) on the screen, below the
/// anchor or above it (``PopupPlacement``), as a Mac menu does. The page keeps its own menu,
/// invisible, so the keyboard, focus and accessibility stay its own: arrows move its highlight and
/// it sends ``update(_:)``; a click or hover here goes back as an event (`pick`, `highlight`), and
/// a click outside the page or the app going inactive as `dismiss`. Placement, motion and the
/// dismiss rules are the shared ``NativePopupHost``'s.
@MainActor
public final class WebPopupHost {
    /// One row of the page's menu.
    public struct Item: Equatable, Sendable {
        public var id: String
        public var label: String
        public var shortcut: String?
        public var checked: Bool
        public var disabled: Bool
        public var separator: Bool
    }

    /// What the page sends: its rows, the highlighted one, the anchor (CSS px in the page's
    /// viewport), the side it prefers and the menu's width (CSS px).
    public struct Model: Equatable, Sendable {
        public var items: [Item]
        public var highlighted: String?
        public var anchor: CGRect
        public var side: PopupPlacement.Side
        public var trailing: Bool
        public var width: CGFloat
        /// A tooltip: one row that takes no clicks and draws no check column.
        public var tooltip: Bool
        /// The page shows nothing with an entrance (a New Tab, Leo 2026-10-22): the menu opens in
        /// one frame; its close still fades.
        public var instant: Bool

        /// Reads `{items:[{id,label,shortcut?,checked?,disabled?,separator?}], highlighted?,
        /// anchor:{left,top,right,bottom}, side:"bottom"|"top", align:"start"|"end", width,
        /// kind?:"menu"|"tooltip", instant?:true}`.
        public init?(_ params: [String: Any]) {
            guard let rows = params["items"] as? [[String: Any]], let anchor = params["anchor"] as? [String: Any],
                  let left = Self.number(anchor["left"]), let top = Self.number(anchor["top"]),
                  let right = Self.number(anchor["right"]), let bottom = Self.number(anchor["bottom"]) else { return nil }
            items = rows.prefix(200).compactMap { row in
                guard let id = row["id"] as? String, id.count <= 64 else { return nil }
                return Item(id: id, label: String((row["label"] as? String ?? "").prefix(300)),
                            shortcut: (row["shortcut"] as? String).map { String($0.prefix(40)) },
                            checked: row["checked"] as? Bool ?? false, disabled: row["disabled"] as? Bool ?? false,
                            separator: row["separator"] as? Bool ?? false)
            }
            highlighted = (params["highlighted"] as? String).flatMap { $0.count <= 64 ? $0 : nil }
            self.anchor = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            side = params["side"] as? String == "top" ? .above : .below
            trailing = params["align"] as? String == "end"
            tooltip = params["kind"] as? String == "tooltip"
            instant = params["instant"] as? Bool ?? false
            width = max(tooltip ? 40 : 120, min(Self.number(params["width"]) ?? 200, 800))
        }

        private static func number(_ value: Any?) -> CGFloat? {
            // A frame from NaN or infinity would throw in AppKit.
            (value as? NSNumber).map { CGFloat(truncating: $0) }.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    /// The page's web view, its zoom (CSS px to points) and where events go to the page.
    private weak var webView: NSView?
    private let zoom: () -> CGFloat
    private let send: ([String: Any]) -> Void
    private var popup: NativePopupHost?
    private var panel: WebPopupPanel? { popup?.panel as? WebPopupPanel }
    private var model: Model?

    public init(webView: NSView, zoom: @escaping () -> CGFloat, send: @escaping ([String: Any]) -> Void) {
        self.webView = webView
        self.zoom = zoom
        self.send = send
    }

    /// The frame the menu is showing at (screen), for tests and `debug.window_list`.
    public var shownFrame: CGRect? { popup?.isShown == true && model != nil ? popup?.cardFrame : nil }

    /// Shows the page's menu on the screen; the reply names the side it took and its frame.
    @discardableResult
    public func show(_ model: Model) -> [String: Any] {
        guard let webView, let window = webView.window, window.isVisible else { return ["shown": false] }
        self.model = model
        let popup = self.popup ?? makePopup()
        self.popup = popup
        guard let panel = popup.panel as? WebPopupPanel else { return ["shown": false] }
        panel.ignoresMouseEvents = model.tooltip
        panel.rows.plain = model.tooltip
        panel.rows.update(model.items, highlighted: model.highlighted)
        let scale = zoom()
        let local = CGRect(x: model.anchor.minX * scale, y: model.anchor.minY * scale,
                           width: model.anchor.width * scale, height: model.anchor.height * scale)
        let flipped = webView.isFlipped ? local : CGRect(x: local.minX, y: webView.bounds.height - local.maxY,
                                                         width: local.width, height: local.height)
        let anchor = window.convertToScreen(webView.convert(flipped, to: nil))
        let size = CGSize(width: model.width * scale, height: panel.rows.contentHeight)
        guard let placed = popup.show(size: size, anchor: anchor, in: window, preferred: model.side,
                                      trailing: model.trailing, entrance: !model.instant) else { return ["shown": false] }
        panel.isClosing = false
        let frame = placed.frame
        return ["shown": true, "side": placed.side == .below ? "bottom" : "top",
                "frame": [frame.minX, frame.minY, frame.width, frame.height]]
    }

    private func makePopup() -> NativePopupHost {
        let popup = NativePopupHost(panel: WebPopupPanel(onPick: { [weak self] id in self?.picked(id) },
                                                         onHover: { [weak self] id in self?.send(["type": "highlight", "id": id]) }))
        // The page closes its own menu on a click in it.
        popup.keepsOpen = { [weak self] event in
            guard let webView = self?.webView, event.window === webView.window else { return false }
            return webView.bounds.contains(webView.convert(event.locationInWindow, from: nil))
        }
        popup.onDismiss = { [weak self] in
            guard let self, model != nil else { return }
            model = nil
            panel?.isClosing = true
            send(["type": "dismiss"])
        }
        return popup
    }

    /// New rows or a new highlight (the page's arrows, its filter); the place stays.
    public func update(_ model: Model) {
        // A menu closing here stays closed: the page may still post an update for it.
        guard self.model != nil, panel?.isVisible == true else { return }
        if model.items != self.model?.items || model.anchor != self.model?.anchor ||
            model.tooltip != self.model?.tooltip || model.width != self.model?.width ||
            model.side != self.model?.side || model.trailing != self.model?.trailing ||
            model.instant != self.model?.instant { show(model); return }
        self.model = model
        panel?.rows.update(model.items, highlighted: model.highlighted)
    }

    public func hide() {
        model = nil
        panel?.isClosing = true
        popup?.hide()
    }

    private func picked(_ id: String) {
        guard model?.items.contains(where: { $0.id == id && !$0.disabled && !$0.separator }) == true else { return }
        send(["type": "pick", "id": id])
        hide()
    }

    /// Ends the menu from this side (its tab hid or closed): the page closes its own as well.
    public func dismiss() {
        guard model != nil else { return }
        send(["type": "dismiss"])
        hide()
    }
}

/// The child panel a page's menu shows in past the window's edge (`debug.window_list` kind
/// `page-popup`).
public final class WebPopupPanel: ContentChildPanel {
    let rows: WebPopupRows
    /// The rows it shows and the height they take (`debug.page_popup`): a frame shorter than
    /// that scrolls.
    public var rowCount: Int { rows.itemCount }
    public var contentHeight: CGFloat { rows.contentHeight }
    /// Fading out after a hide: gone for the page and for `debug.page_popup`.
    public internal(set) var isClosing = false

    init(onPick: @escaping (String) -> Void, onHover: @escaping (String) -> Void) {
        rows = WebPopupRows(onPick: onPick, onHover: onHover)
        super.init()
        identifier = NSUserInterfaceItemIdentifier("cmux.page-popup")
        setAccessibilityElement(false)
        // Rows the screen cannot fit scroll, as a Mac menu's do.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        SystemScrollers.follow(scroll)
        scroll.documentView = rows
        let surface = Glass.makeOverlayPanel(content: scroll, cornerRadius: PopupStyle.standard.cornerRadius)
        // The one popup shadow (POLISH: subtle shadows, one elevation), like the page's own menus;
        // the window's shadow was the system's, heavier.
        adoptPopupStyle(card: surface)
    }

    /// The menu's card (screen), without the shadow band around it.
    public var cardFrame: CGRect { PopupStyle.standard.cardFrame(inWindow: frame) }
}

/// The menu's rows, each a shared ``PopupRowView`` (a check column, the title, the shortcut);
/// separators as hairlines. The page owns the one highlight: the pointer reports it (`onHover`).
final class WebPopupRows: NSView {
    private let onPick: (String) -> Void
    private let onHover: (String) -> Void
    private var items: [WebPopupHost.Item] = []
    private var rows: [(item: WebPopupHost.Item, view: NSView)] = []
    var itemCount: Int { items.filter { !$0.separator }.count }
    private var highlighted: String?
    /// No check column (a tooltip's text).
    var plain = false
    private var builtPlain = false
    private let style = PopupStyle.standard
    private static let separatorHeight: CGFloat = 9

    init(onPick: @escaping (String) -> Void, onHover: @escaping (String) -> Void) {
        self.onPick = onPick
        self.onHover = onHover
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    nonisolated override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var contentHeight: CGFloat {
        2 * style.padding + items.reduce(0) { $0 + ($1.separator ? Self.separatorHeight : style.rowHeight) }
    }

    func update(_ items: [WebPopupHost.Item], highlighted: String?) {
        if plain != builtPlain || rows.isEmpty != items.isEmpty || (items != self.items && !updateLabelsInPlace(items)) {
            rebuild(items)
        }
        self.highlighted = highlighted
        for (item, view) in rows { (view as? PopupRowView)?.isHighlighted = item.id == highlighted }
        setFrameSize(NSSize(width: superview?.bounds.width ?? frame.width, height: contentHeight))
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollToHighlight()
    }

    /// Keeps native row views when only tooltip labels change; menu structure and state changes
    /// still rebuild their rows.
    private func updateLabelsInPlace(_ next: [WebPopupHost.Item]) -> Bool {
        guard plain, plain == builtPlain, next.count == items.count, rows.count == next.count,
              zip(items, next).allSatisfy({ old, new in
                  old.id == new.id && old.shortcut == new.shortcut && old.checked == new.checked &&
                      old.disabled == new.disabled && old.separator == new.separator
              }) else { return false }
        for (index, item) in next.enumerated() {
            guard let row = rows[index].view as? PopupRowView else { return false }
            if row.titleLabel.stringValue != item.label {
                row.titleLabel.stringValue = item.label
                row.setAccessibilityLabel(item.label)
                row.needsLayout = true
            }
        }
        self.items = next
        return true
    }

    private func rebuild(_ items: [WebPopupHost.Item]) {
        self.items = items
        builtPlain = plain
        rows.forEach { $0.view.removeFromSuperview() }
        var layout = PopupRowView.Layout()
        layout.leadingColumn = plain ? 1 : 15
        layout.hoverFills = false
        rows = items.map { item -> (item: WebPopupHost.Item, view: NSView) in
            guard !item.separator else { return (item, WebPopupSeparator()) }
            let row = PopupRowView(leading: PopupRowView.checkMark(item.checked), title: item.label,
                                   trailing: item.shortcut.flatMap { $0.isEmpty ? nil : PopupRowView.shortcut($0) },
                                   layout: layout, interactive: !plain)
            row.isEnabled = !item.disabled
            // The page keeps its own menu for accessibility.
            row.hideFromAccessibility()
            row.onHover = { [weak self] in self?.hovered(item.id) }
            row.onActivate = { [weak self] in self?.onPick(item.id) }
            return (item, row)
        }
        for (_, view) in rows {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    private func hovered(_ id: String) {
        guard id != highlighted else { return }
        highlighted = id
        for (item, view) in rows { (view as? PopupRowView)?.isHighlighted = item.id == id }
        onHover(id)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.width]
    }

    override func layout() {
        super.layout()
        var y = style.padding
        for (item, view) in rows {
            let height = item.separator ? Self.separatorHeight : style.rowHeight
            view.frame = CGRect(x: style.padding, y: y, width: max(0, bounds.width - 2 * style.padding), height: height)
            y += height
        }
    }

    private func scrollToHighlight() {
        guard let highlighted, let row = rows.first(where: { $0.item.id == highlighted })?.view else { return }
        scrollToVisible(row.frame)
    }
}

/// A hairline between groups of a page menu's rows.
private final class WebPopupSeparator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        performWithTheme {
            Palette.separator.setFill()
            NSRect(x: 6, y: bounds.midY.rounded(.down), width: max(0, bounds.width - 12), height: 1).fill()
        }
    }
}
