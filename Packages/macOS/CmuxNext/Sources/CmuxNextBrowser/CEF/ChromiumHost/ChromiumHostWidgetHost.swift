import AppKit

/// What the widgets send to the Chromium host: the host's wire in the app, a recorder in tests.
protocol ChromiumHostWidgetWire: AnyObject {
    /// A widget cmux places (``ChromiumHostWidgetKind/Placement/reportsGeometry``) moved or resized on screen.
    func widget(_ widget: ChromiumHostWidgetID, movedTo geometry: ChromiumHostGeometry)
    /// The person closed the widget in cmux (a window's close button, a click away from an
    /// extension popup). cmux has already taken it down; the host closes it.
    func dismiss(_ widget: ChromiumHostWidgetID)
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Input to the widget, as a page view's input goes to its page.
    func widget(_ widget: ChromiumHostWidgetID, input frame: ChromiumHostFrame)
    #endif
}

/// Shows the Chromium host's widgets in cmux (host mode, feature `chromiumHostWidgets`):
/// one ``ChromiumHostPageView`` per widget, in the window or container its
/// ``ChromiumHostWidgetKind/Placement`` names, with the widget's input and, where cmux places
/// it, its geometry going to the host. The host owns each widget's life: WIDGET_CONTEXT
/// shows or changes one (``show(_:)``), WIDGET_GONE ends it (``remove(_:)``), and a person's
/// close takes it down at once and tells the host (``ChromiumHostWidgetWire/dismiss(_:)``).
final class ChromiumHostWidgetHost {
    /// What the host makes and orders windows with; tests pass windows that never show.
    struct Seams {
        var makeView: @MainActor (NSRect) -> ChromiumHostPageView = { ChromiumHostPageView(frame: $0, inputTarget: .view) }
        var makePanel: @MainActor (_ frame: CGRect, _ takesKey: Bool) -> ChromiumHostWidgetPanel = {
            ChromiumHostWidgetPanel(frame: $0, takesKey: $1)
        }
        /// A picture-in-picture panel of the content size, placed on the screen (the owner's window's).
        var makePictureInPicturePanel: @MainActor (_ size: CGSize, _ screen: NSScreen?, _ keepsAspectRatio: Bool,
                                                   _ takesKey: Bool) -> ChromiumHostPictureInPicturePanel = {
            ChromiumHostPictureInPicturePanel(contentSize: $0, on: $1, keepsAspectRatio: $2, takesKey: $3)
        }
        /// An undocked DevTools window: the same window the in-process DevTools uses.
        var makeWindow: @MainActor (_ frame: CGRect, _ owner: NSWindow?) -> CEFDevToolsWindow = {
            CEFDevToolsWindow(frame: $0, owner: $1)
        }
        var order: @MainActor (_ window: NSWindow, _ parent: NSWindow?, _ key: Bool) -> Void = {
            ChromiumHostWidgetHost.orderIn($0, parent: $1, key: $2)
        }
        /// The primary display's frame maxY (Chromium's screen origin is its top left).
        var primaryScreenTop: @MainActor () -> CGFloat? = { NSScreen.screens.first?.frame.maxY }
    }

    /// The container a ``ChromiumHostWidgetKind/Placement/fill`` or
    /// ``ChromiumHostWidgetKind/Placement/inPage`` widget shows in: one per owner and kind.
    private struct SlotKey: Hashable {
        var owner: Int32
        var kind: ChromiumHostWidgetKind
    }

    private struct Slot {
        weak var container: NSView?
    }

    /// One widget the host shows now.
    private final class Entry {
        var context: ChromiumHostWidgetContext
        let view: ChromiumHostPageView
        /// Order of arrival: the newest widget of a container shows in it.
        let serial: UInt64
        /// The cmux window it shows in (anchored and window placements).
        var window: NSWindow?
        /// An undocked DevTools window's delegate (the window holds it weakly).
        var windowDelegate: ChromiumHostWidgetWindowDelegate?

        init(context: ChromiumHostWidgetContext, view: ChromiumHostPageView, serial: UInt64) {
            self.context = context
            self.view = view
            self.serial = serial
        }

        var slot: SlotKey { SlotKey(owner: context.owner, kind: context.kind) }
    }

    /// A shown widget, for `debug.cef` and the bench's native UI rows.
    struct Diagnostic: Equatable {
        var widget: ChromiumHostWidgetID
        var kind: ChromiumHostWidgetKind
        var owner: Int32
        var contextID: UInt32
        /// Its view is in a window.
        var shown: Bool
        /// Its view's AppKit screen rect, zero while not shown.
        var screenFrame: CGRect
    }

    private let wire: any ChromiumHostWidgetWire
    /// The cmux window that shows a browser's page (an anchored widget's parent).
    private let ownerWindow: @MainActor (Int32) -> NSWindow?
    private let seams: Seams
    private var entries: [ChromiumHostWidgetID: Entry] = [:]
    private var slots: [SlotKey: Slot] = [:]
    private var nextSerial: UInt64 = 0
    /// Widgets the person closed whose WIDGET_GONE has not come, with their owners: a WIDGET_CONTEXT
    /// already on its way (an extension popup resizing to its content) must not show one again. Chrome
    /// ignores updates to a widget it is closing the same way (`Widget::IsClosed` after `Widget::Close`,
    /// ui/views/widget/widget.cc).
    private var dismissed: [ChromiumHostWidgetID: Int32] = [:]

    init(wire: any ChromiumHostWidgetWire, ownerWindow: @escaping @MainActor (Int32) -> NSWindow?, seams: Seams = Seams()) {
        self.wire = wire
        self.ownerWindow = ownerWindow
        self.seams = seams
    }

    /// The widgets shown now, by id.
    var diagnostics: [Diagnostic] {
        entries.values.sorted { $0.context.widget.rawValue < $1.context.widget.rawValue }.map { entry in
            let view = entry.view
            let frame = view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } ?? .zero
            return Diagnostic(widget: entry.context.widget, kind: entry.context.kind, owner: entry.context.owner,
                              contextID: entry.context.contextID, shown: view.window != nil, screenFrame: frame)
        }
    }

    /// WIDGET_CONTEXT: shows the widget, or moves it to its new context or bounds. An
    /// unchanged context costs one comparison.
    func show(_ context: ChromiumHostWidgetContext) {
        guard dismissed[context.widget] == nil else { return }
        if let entry = entries[context.widget] {
            guard entry.context != context else { return }
            guard entry.context.kind == context.kind, entry.context.owner == context.owner else {
                // Another widget under a reused id: the old one is gone.
                takeDown(context.widget)
                show(context)
                return
            }
            entry.context = context
            _ = entry.view.show(contextID: context.contextID)
            place(entry)
            return
        }
        nextSerial += 1
        let entry = Entry(context: context, view: seams.makeView(NSRect(origin: .zero, size: context.bounds.size)),
                          serial: nextSerial)
        entries[context.widget] = entry
        connect(entry)
        _ = entry.view.show(contextID: context.contextID)
        place(entry)
    }

    /// WIDGET_GONE: the widget's view and window go, and an older widget of the same container
    /// shows again. A context for its id after this is a new widget.
    func remove(_ widget: ChromiumHostWidgetID) {
        dismissed[widget] = nil
        takeDown(widget)
    }

    /// The widget's view and window go, and an older widget of the same container shows again.
    private func takeDown(_ widget: ChromiumHostWidgetID) {
        guard let entry = entries.removeValue(forKey: widget) else { return }
        entry.view.onGeometry = nil
        #if DEBUG || CMUX_BENCH_HOOKS
        entry.view.sink = nil
        #endif
        _ = entry.view.show(contextID: 0)
        entry.view.removeFromSuperview()
        if let window = entry.window {
            entry.window = nil
            (window as? CEFDevToolsWindow)?.onClose = nil
            (window as? ChromiumHostWidgetPanel)?.onResignKey = nil
            window.delegate = nil
            entry.windowDelegate = nil
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            window.close()
        }
        if let next = newest(in: entry.slot) { place(next) }
    }

    /// Shows the owner's widget of `kind` (a ``ChromiumHostWidgetKind/Placement/fill`` or
    /// ``ChromiumHostWidgetKind/Placement/inPage`` kind) in `container`, now or when its context
    /// comes; nil takes it out until a container is named again.
    func place(_ kind: ChromiumHostWidgetKind, owner: Int32, in container: NSView?) {
        guard kind.placement == .fill || kind.placement == .inPage else { return }
        let key = SlotKey(owner: owner, kind: kind)
        slots[key] = container.map { Slot(container: $0) }
        if let entry = newest(in: key) { place(entry) }
    }

    /// The owner's browser closed (BEFORE_CLOSE): its containers and widgets go.
    func ownerClosed(_ browser: Int32) {
        slots = slots.filter { $0.key.owner != browser }
        dismissed = dismissed.filter { $0.value != browser }
        for widget in entries.values.filter({ $0.context.owner == browser }).map(\.context.widget) {
            takeDown(widget)
        }
    }

    /// The host ended: every widget goes, and no WIDGET_GONE comes for them (a new host shows its own).
    func hostEnded() {
        slots.removeAll()
        dismissed.removeAll()
        for widget in Array(entries.keys) {
            takeDown(widget)
        }
    }

    private func connect(_ entry: Entry) {
        let wire = wire
        let widget = entry.context.widget
        #if DEBUG || CMUX_BENCH_HOOKS
        // A widget's wire stamps no input seq: no key comes back as KEY_UNHANDLED.
        entry.view.sink = { frame in
            wire.widget(widget, input: frame)
            return nil
        }
        #endif
        if entry.context.kind.placement.reportsGeometry {
            entry.view.onGeometry = { geometry in wire.widget(widget, movedTo: geometry) }
        }
    }

    /// The person closed the widget: it goes now and the host closes it.
    private func dismiss(_ widget: ChromiumHostWidgetID) {
        guard let entry = entries[widget] else { return }
        dismissed[widget] = entry.context.owner
        takeDown(widget)
        wire.dismiss(widget)
    }

    /// The newest widget of a container (O(widgets); a host shows a handful).
    private func newest(in key: SlotKey) -> Entry? {
        guard key.kind.placement == .fill || key.kind.placement == .inPage else { return nil }
        return entries.values.filter { $0.slot == key }.max { $0.serial < $1.serial }
    }

    private func place(_ entry: Entry) {
        switch entry.context.kind.placement {
        case .anchored(let takesKey): placeAnchored(entry, takesKey: takesKey)
        case .window: placeInWindow(entry)
        case .fill, .inPage: placeInContainer(entry)
        case .floating(let keepsAspectRatio, let takesKey): placeFloating(entry, keepsAspectRatio: keepsAspectRatio, takesKey: takesKey)
        }
    }

    /// Picture-in-picture: its own panel, not a child of the opener's window, so it stays when that
    /// window is minimized or on another space. The host decides the size; cmux where it is.
    private func placeFloating(_ entry: Entry, keepsAspectRatio: Bool, takesKey: Bool) {
        let size = entry.context.bounds.size
        if let panel = entry.window as? ChromiumHostPictureInPicturePanel {
            panel.take(contentSize: size, keepsAspectRatio: keepsAspectRatio)
            return
        }
        let panel = seams.makePictureInPicturePanel(size, ownerWindow(entry.context.owner)?.screen ?? NSScreen.main,
                                                    keepsAspectRatio, takesKey)
        if let content = panel.contentView {
            entry.view.frame = content.bounds
            entry.view.autoresizingMask = [.width, .height]
            content.addSubview(entry.view)
        }
        entry.window = panel
        seams.order(panel, nil, takesKey)
    }

    private func placeAnchored(_ entry: Entry, takesKey: Bool) {
        let context = entry.context
        guard let top = seams.primaryScreenTop() else { return }
        let frame = context.screenFrame(primaryTop: top)
        if let window = entry.window {
            if window.frame != frame { window.setFrame(frame, display: false) }
            return
        }
        let panel = seams.makePanel(frame, takesKey)
        if let content = panel.contentView {
            entry.view.frame = content.bounds
            content.addSubview(entry.view)
        }
        entry.window = panel
        if takesKey {
            panel.onResignKey = { [weak self] in self?.dismiss(context.widget) }
        }
        seams.order(panel, ownerWindow(context.owner), takesKey)
    }

    private func placeInWindow(_ entry: Entry) {
        let context = entry.context
        if let window = entry.window {
            window.title = context.title
            return
        }
        guard let top = seams.primaryScreenTop() else { return }
        let window = seams.makeWindow(context.screenFrame(primaryTop: top), ownerWindow(context.owner))
        window.title = context.title
        window.adopt(entry.view)
        window.onClose = { [weak self] in self?.dismiss(context.widget) }
        entry.window = window
        let delegate = ChromiumHostWidgetWindowDelegate()
        window.delegate = delegate
        entry.windowDelegate = delegate
        seams.order(window, nil, true)
    }

    /// A fill widget takes its container's bounds; an in-page one (the side panel) sits at
    /// its bounds, DIPs from the top left of its owner's page, which the container shows.
    private func placeInContainer(_ entry: Entry) {
        guard newest(in: entry.slot) === entry, let container = slots[entry.slot]?.container else {
            entry.view.removeFromSuperview()
            return
        }
        for other in entries.values where other.slot == entry.slot && other !== entry {
            other.view.removeFromSuperview()
        }
        let frame: CGRect
        if entry.context.kind.placement == .fill {
            entry.view.autoresizingMask = [.width, .height]
            frame = container.bounds
        } else {
            let bounds = entry.context.bounds
            let minY = container.isFlipped ? bounds.minY : container.bounds.height - bounds.maxY
            entry.view.autoresizingMask = container.isFlipped ? [] : [.minYMargin]
            frame = CGRect(x: bounds.minX, y: minY, width: bounds.width, height: bounds.height)
        }
        if entry.view.superview !== container {
            if entry.context.kind.placement == .fill {
                // Under the container's other views (a crash page, a find bar), as a tab's page is.
                container.addSubview(entry.view, positioned: .below, relativeTo: nil)
            } else {
                // Over its owner's page, which is at the bottom of the container.
                container.addSubview(entry.view)
            }
        }
        if entry.view.frame != frame { entry.view.frame = frame }
    }

    /// Orders `window` in: as a child of `parent` (it moves with the page's window, as
    /// Chrome's bubbles and popups do), key when it takes typing.
    static func orderIn(_ window: NSWindow, parent: NSWindow?, key: Bool) {
        if let parent, window.parent !== parent { parent.addChildWindow(window, ordered: .above) }
        if key { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    }
}
