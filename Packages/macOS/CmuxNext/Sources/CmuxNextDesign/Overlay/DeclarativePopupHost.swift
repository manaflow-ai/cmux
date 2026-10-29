import AppKit

/// A generated popup model rendered by AppKit, including editable fields and native child menus.
@MainActor
final class DeclarativePopupHost {
    private weak var webView: NSView?
    private let zoom: () -> CGFloat
    private let send: ([String: Any]) -> Void
    private let panel = NativePopupPanel(identifier: "cmux.page-popup.native")
    private let content = NativePopupContent()
    private let popup: NativePopupHost
    private let surface: OverlaySurfaceView
    private var model: NativePopupModel?
    private var child: DeclarativePopupHost?
    private var childRowID: String?
    private var shownAnchor: CGRect?
    private weak var shownParent: NSWindow?
    private weak var parent: DeclarativePopupHost?
    private weak var returnResponder: NSResponder?
    private weak var returnWindow: NSWindow?
    private var retired: [String: Int] = [:]

    init(webView: NSView, zoom: @escaping () -> CGFloat, send: @escaping ([String: Any]) -> Void) {
        self.webView = webView
        self.zoom = zoom
        self.send = send
        popup = NativePopupHost(panel: panel)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        SystemScrollers.follow(scroll)
        scroll.documentView = content
        surface = Glass.makeOverlayPanel(content: scroll, cornerRadius: PopupStyle.standard.cornerRadius)
        surface.samplesBehindWindow = true
        panel.adoptPopupStyle(card: surface)
        popup.onDismiss = { [weak self] in self?.dismiss(reason: "outside") }
        popup.keepsOpen = { [weak self] event in self?.root.contains(event.window) == true }
        // NativePopupHost installs key-loss handling and the click/escape monitors. Keep that
        // callback intact: replacing it here would skip the host's focus restoration path.
        content.emit = { [weak self] type, id, value in self?.event(type, id: id, value: value) }
        content.openSubmenu = { [weak self] row, view in self?.open(row, from: view) }
        content.dismiss = { [weak self] in self?.dismiss(reason: "escape") }
    }

    var shownFrame: CGRect? { popup.isShown && model != nil ? popup.cardFrame : nil }
    var activeID: String? { model?.id }

    private var root: DeclarativePopupHost { parent?.root ?? self }

    private func contains(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === panel || child?.contains(window) == true
    }

    func show(_ next: NativePopupModel, screenAnchor: CGRect? = nil, in parentWindow: NSWindow? = nil) -> [String: Any] {
        guard next.isValid, let webView, let window = parentWindow ?? webView.window, window.isVisible else { return ["shown": false] }
        guard next.revision > (retired[next.id] ?? -1) else { return ["shown": false] }
        if let current = model, current.id == next.id, next.revision < current.revision { return ["shown": false] }
        let opening = !popup.isShown || model?.id != next.id
        if let current = model, current.id != next.id {
            retire(current.id, revision: current.revision)
            deliver(NativePopupEvent(type: .dismiss, popupId: current.id, revision: current.revision, reason: "replaced"))
        }
        if opening {
            child?.hide()
            child = nil
            returnWindow = window
            returnResponder = window.firstResponder
        }
        model = next
        content.setFrameSize(NSSize(width: next.width * zoom(), height: content.frame.height))
        content.update(next)
        let scale = zoom()
        let local = CGRect(x: next.anchor.left * scale, y: next.anchor.top * scale,
                           width: (next.anchor.right - next.anchor.left) * scale,
                           height: (next.anchor.bottom - next.anchor.top) * scale)
        let flipped = webView.isFlipped ? local : CGRect(x: local.minX, y: webView.bounds.height - local.maxY,
                                                        width: local.width, height: local.height)
        let anchor = screenAnchor ?? window.convertToScreen(webView.convert(flipped, to: nil))
        shownAnchor = anchor
        shownParent = window
        panel.adoptThemeScope(of: webView)
        surface.applyTheme()
        guard let placed = popup.show(size: NSSize(width: next.width * scale, height: content.contentHeight),
                                      anchor: anchor, in: window, preferred: next.side == .top ? .above : .below,
                                      trailing: next.align == .end, makeKey: opening && parent == nil, entrance: false) else { model = nil; return ["shown": false] }
        if opening { content.focusInitial() }
        return ["shown": true, "popupId": next.id, "revision": next.revision,
                "frame": [placed.frame.minX, placed.frame.minY, placed.frame.width, placed.frame.height]]
    }

    func update(_ next: NativePopupModel) {
        guard let current = model, current.id == next.id, next.revision > current.revision, popup.isShown else { return }
        _ = show(next, screenAnchor: parent == nil ? nil : shownAnchor, in: shownParent)
        if let child, let childRowID, let row = Self.flatten(next.rows).first(where: { $0.id == childRowID }), let rows = row.children {
            var submenu = next
            submenu.rows = rows
            submenu.rail = nil
            submenu.footer = nil
            submenu.search = nil
            submenu.title = row.label
            submenu.parentId = next.id
            child.update(submenu)
        } else {
            child?.hide()
            child = nil
            childRowID = nil
        }
    }

    func hide(id: String? = nil, revision: Int? = nil) {
        if let id, let revision {
            guard id == model?.id, revision == model?.revision else { return }
            // Only the currently displayed identity may create a tombstone. A stale hide
            // for an already replaced or dismissed revision must not block a later show.
            retire(id, revision: revision)
        } else if id != nil { return }
        if let model { retire(model.id, revision: model.revision) }
        child?.hide()
        child = nil
        model = nil
        popup.hide()
        if let window = returnWindow, window.isVisible, let responder = returnResponder {
            window.makeFirstResponder(responder)
        }
    }

    private func retire(_ id: String, revision: Int) {
        retired[id] = max(retired[id] ?? -1, revision)
        // The native page owns bounded recent tombstones, not the lifetime of every React mount.
        if retired.count > 256, let oldest = retired.keys.first(where: { $0 != id && $0 != model?.id }) { retired.removeValue(forKey: oldest) }
    }

    func dismiss(reason: String) {
        guard let model else { return }
        let event = NativePopupEvent(type: .dismiss, popupId: model.id, revision: model.revision, reason: reason)
        deliver(event)
        hide()
    }

    private func event(_ type: NativePopupEventType, id: String?, value: String?) {
        guard let model, popup.isShown, let id else { return }
        let rows = Self.flatten((model.rail ?? []) + model.rows + (model.footer ?? []))
        let row = rows.first { $0.id == id }
        let actionParent = rows.first { $0.actions?.contains(where: { $0.id == id }) == true }
        let action = actionParent?.actions?.first { $0.id == id }
        switch type {
        case .search:
            guard model.search?.id == id, model.search?.disabled != true else { return }
        case .pick:
            guard (row?.kind == .action && row?.disabled != true) ||
                  (action != nil && action?.disabled != true && actionParent?.disabled != true) else { return }
        case .change:
            guard let row, row.disabled != true, [.toggle, .choice, .slider, .textField].contains(row.kind) else { return }
            if row.kind == .choice, row.options?.contains(where: { $0.id == value && $0.disabled != true }) != true { return }
        case .highlight:
            guard let row, row.disabled != true else { return }
        case .dismiss: return
        }
        deliver(NativePopupEvent(type: type, popupId: model.id, revision: model.revision, id: id, value: value))
        if type == .pick, (action?.keepOpen ?? row?.keepOpen) != true { root.hide() }
    }

    private func deliver(_ event: NativePopupEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        send(object)
    }

    private func open(_ row: NativePopupRow, from view: NSView) {
        guard let model, let rows = row.children, !rows.isEmpty, let webView else { return }
        child?.hide()
        let submenu = DeclarativePopupHost(webView: webView, zoom: zoom, send: send)
        submenu.parent = self
        child = submenu
        childRowID = row.id
        var next = model
        // Events retain the root popup identity/revision; consumers need no second listener.
        next.rows = rows
        next.rail = nil
        next.footer = nil
        next.title = row.label
        next.search = nil
        next.highlighted = nil
        next.parentId = model.id
        let rowFrame = panel.convertToScreen(view.convert(view.bounds, to: nil))
        let anchor = CGRect(x: rowFrame.maxX, y: rowFrame.maxY, width: 0, height: 0)
        _ = submenu.show(next, screenAnchor: anchor, in: panel)
    }

    private static func flatten(_ rows: [NativePopupRow]) -> [NativePopupRow] {
        rows.flatMap { [$0] + flatten($0.children ?? []) }
    }
}
