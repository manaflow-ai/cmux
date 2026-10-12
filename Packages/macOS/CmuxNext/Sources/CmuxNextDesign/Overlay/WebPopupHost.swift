public import AppKit

/// A page's menu drawn past its window's edge (cx-6k6cg). A page menu that has no room above or
/// below its anchor inside the web view hands its rows here: they show in a child panel of the
/// window (``ContentChildPanel``, the ``Glass/makeOverlayPanel`` surface) on the screen, below the
/// anchor or above it (``PopupPlacement``), as a Mac menu does. The page keeps its own menu,
/// invisible, so the keyboard, focus and accessibility stay its own: arrows move its highlight and
/// it sends ``update(_:)``; a click or hover here goes back as an event (`pick`, `highlight`), and
/// a click outside the page or the app going inactive as `dismiss`.
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

        /// Reads `{items:[{id,label,shortcut?,checked?,disabled?,separator?}], highlighted?,
        /// anchor:{left,top,right,bottom}, side:"bottom"|"top", align:"start"|"end", width}`.
        public init?(_ params: [String: Any]) {
            guard let rows = params["items"] as? [[String: Any]], let anchor = params["anchor"] as? [String: Any],
                  let left = Self.number(anchor["left"]), let top = Self.number(anchor["top"]),
                  let right = Self.number(anchor["right"]), let bottom = Self.number(anchor["bottom"]) else { return nil }
            items = rows.prefix(200).compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return Item(id: id, label: String((row["label"] as? String ?? "").prefix(300)),
                            shortcut: (row["shortcut"] as? String).map { String($0.prefix(40)) },
                            checked: row["checked"] as? Bool ?? false, disabled: row["disabled"] as? Bool ?? false,
                            separator: row["separator"] as? Bool ?? false)
            }
            highlighted = params["highlighted"] as? String
            self.anchor = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            side = params["side"] as? String == "top" ? .above : .below
            trailing = params["align"] as? String == "end"
            width = max(120, min(Self.number(params["width"]) ?? 200, 800))
        }

        private static func number(_ value: Any?) -> CGFloat? {
            (value as? NSNumber).map { CGFloat(truncating: $0) }
        }
    }

    /// The page's web view, its zoom (CSS px to points) and where events go to the page.
    private weak var webView: NSView?
    private let zoom: () -> CGFloat
    private let send: ([String: Any]) -> Void
    private var panel: WebPopupPanel?
    private var model: Model?
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?

    public init(webView: NSView, zoom: @escaping () -> CGFloat, send: @escaping ([String: Any]) -> Void) {
        self.webView = webView
        self.zoom = zoom
        self.send = send
    }

    /// The frame the menu is showing at (screen), for tests and `debug.window_list`.
    public var shownFrame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    /// Shows the page's menu on the screen; the reply names the side it took and its frame.
    @discardableResult
    public func show(_ model: Model) -> [String: Any] {
        guard let webView, let window = webView.window, window.isVisible else { return ["shown": false] }
        self.model = model
        let panel = self.panel ?? WebPopupPanel(onPick: { [weak self] id in self?.picked(id) },
                                                onHover: { [weak self] id in self?.send(["type": "highlight", "id": id]) })
        self.panel = panel
        panel.rows.update(model.items, highlighted: model.highlighted)
        let scale = zoom()
        let local = CGRect(x: model.anchor.minX * scale, y: model.anchor.minY * scale,
                           width: model.anchor.width * scale, height: model.anchor.height * scale)
        let flipped = webView.isFlipped ? local : CGRect(x: local.minX, y: webView.bounds.height - local.maxY,
                                                         width: local.width, height: local.height)
        let anchor = window.convertToScreen(webView.convert(flipped, to: nil))
        guard let screen = PopupPlacement.screen(for: anchor, fallback: window) else { return ["shown": false] }
        let size = CGSize(width: model.width * scale, height: panel.rows.contentHeight)
        let (frame, side) = PopupPlacement.frame(anchor: anchor, size: size, preferred: model.side,
                                                 trailing: model.trailing, screen: screen.visibleFrame)
        panel.setFrame(frame, display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.level = window.level
        panel.orderFront(nil)
        panel.invalidateShadow()
        watch(window)
        return ["shown": true, "side": side == .below ? "bottom" : "top",
                "frame": [frame.minX, frame.minY, frame.width, frame.height]]
    }

    /// New rows or a new highlight (the page's arrows, its filter); the place stays.
    public func update(_ model: Model) {
        guard panel?.isVisible == true else { return }
        if model.items != self.model?.items || model.anchor != self.model?.anchor { show(model); return }
        self.model = model
        panel?.rows.update(model.items, highlighted: model.highlighted)
    }

    public func hide() {
        model = nil
        unwatch()
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func picked(_ id: String) {
        guard model?.items.contains(where: { $0.id == id && !$0.disabled && !$0.separator }) == true else { return }
        send(["type": "pick", "id": id])
        hide()
    }

    private func dismiss() {
        guard model != nil else { return }
        send(["type": "dismiss"])
        hide()
    }

    /// A click anywhere but the menu and the page (the page closes its own menu on a click in it),
    /// the app going inactive, or the window moving, resizing or closing ends the menu.
    private func watch(_ window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [(NSNotification.Name, AnyObject?)] = [
            (NSApplication.didResignActiveNotification, nil), (NSWindow.willMoveNotification, window),
            (NSWindow.didResizeNotification, window), (NSWindow.willCloseNotification, window),
            (NSWindow.didMiniaturizeNotification, window),
        ]
        observers = names.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            if let webView = self.webView, event.window === webView.window,
               webView.bounds.contains(webView.convert(event.locationInWindow, from: nil)) { return event }
            self.dismiss()
            return event
        }
    }

    private func unwatch() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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

    init(onPick: @escaping (String) -> Void, onHover: @escaping (String) -> Void) {
        rows = WebPopupRows(onPick: onPick, onHover: onHover)
        super.init()
        identifier = NSUserInterfaceItemIdentifier("cmux.page-popup")
        hasShadow = true
        setAccessibilityElement(false)
        // Rows the screen cannot fit scroll, as a Mac menu's do.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = rows
        let surface = Glass.makeOverlayPanel(content: scroll, cornerRadius: PopupStyle.standard.cornerRadius)
        surface.translatesAutoresizingMaskIntoConstraints = true
        contentView = surface
    }
}

/// The menu's rows: a check column, the title, the shortcut; separators as hairlines.
final class WebPopupRows: NSView {
    private let onPick: (String) -> Void
    private let onHover: (String) -> Void
    private var items: [WebPopupHost.Item] = []
    var itemCount: Int { items.filter { !$0.separator }.count }
    private var highlighted: String?
    private var tracking: NSTrackingArea?
    private let style = PopupStyle.standard
    private static let separatorHeight: CGFloat = 9

    init(onPick: @escaping (String) -> Void, onHover: @escaping (String) -> Void) {
        self.onPick = onPick
        self.onHover = onHover
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var contentHeight: CGFloat {
        2 * style.padding + items.reduce(0) { $0 + ($1.separator ? Self.separatorHeight : style.rowHeight) }
    }

    func update(_ items: [WebPopupHost.Item], highlighted: String?) {
        self.items = items
        self.highlighted = highlighted
        setFrameSize(NSSize(width: superview?.bounds.width ?? frame.width, height: contentHeight))
        scrollToHighlight()
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.width]
    }

    private func rowFrames() -> [(WebPopupHost.Item, CGRect)] {
        var y = style.padding
        return items.map { item in
            let height = item.separator ? Self.separatorHeight : style.rowHeight
            defer { y += height }
            return (item, CGRect(x: style.padding, y: y, width: bounds.width - 2 * style.padding, height: height))
        }
    }

    private func scrollToHighlight() {
        guard let highlighted, let frame = rowFrames().first(where: { $0.0.id == highlighted })?.1 else { return }
        scrollToVisible(frame)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = Typography.body
        let check = "✓" as NSString
        let inset: CGFloat = 22
        for (item, frame) in rowFrames() where frame.intersects(dirtyRect) {
            if item.separator {
                Palette.separator.setFill()
                NSRect(x: frame.minX + 6, y: frame.midY.rounded(.down), width: frame.width - 12, height: 1).fill()
                continue
            }
            if item.id == highlighted, !item.disabled {
                Palette.hoverFill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: style.rowCornerRadius, yRadius: style.rowCornerRadius).fill()
            }
            let color = item.disabled ? Palette.textTertiary : Palette.textPrimary
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let lineHeight = font.ascender - font.descender
            let y = frame.minY + (frame.height - lineHeight) / 2
            if item.checked { check.draw(at: NSPoint(x: frame.minX + 7, y: y), withAttributes: attributes) }
            var trailing = frame.maxX - 8
            if let shortcut = item.shortcut, !shortcut.isEmpty {
                let text = shortcut as NSString
                let quiet: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.textTertiary]
                let width = text.size(withAttributes: quiet).width
                trailing -= width
                text.draw(at: NSPoint(x: trailing, y: y), withAttributes: quiet)
                trailing -= 12
            }
            let label = NSRect(x: frame.minX + inset, y: y, width: max(0, trailing - frame.minX - inset), height: lineHeight)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (item.label as NSString).draw(with: label, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: attributes.merging([.paragraphStyle: paragraph]) { $1 })
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func item(at event: NSEvent) -> WebPopupHost.Item? {
        let point = convert(event.locationInWindow, from: nil)
        return rowFrames().first { $0.1.contains(point) && !$0.0.separator && !$0.0.disabled }?.0
    }

    override func mouseMoved(with event: NSEvent) {
        guard let item = item(at: event), item.id != highlighted else { return }
        highlighted = item.id
        needsDisplay = true
        onHover(item.id)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if let item = item(at: event) { onPick(item.id) }
    }
}
