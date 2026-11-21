import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
import ImageIO
import UniformTypeIdentifiers

/// Point at Element (Inspect Element) for cmux NEXT's own UI: the HTML/React pages the app hosts (an agent chat,
/// `AgentPaneView`) and its native tabs, panes and sidebar rows (ask-5077a4ec48: "point to the actual ui sorta like
/// devtools/react devtools and right click elements to copy and show them to the agent").
///
/// It costs nothing until a pick starts (shadow-leo's rule for bringing native UI back): no monitor, observer,
/// overlay or hit-test tree exists outside `start()`...`stop()`. While picking, a move over native UI hit-tests the
/// window once and outlines the element it names (one overlay, moved, not remade); a click sends it to the chat, a
/// right-click copies it, Up and Down walk out to its container and back, Return picks, Esc ends. `stop()` drops all
/// of it again.
@MainActor
final class UIInspectorController {
    private weak var services: AppServices?
    /// The picker's monitor, installed only between `start()` and `stop()`.
    private var monitor: Any?
    private var inspectNotification: NSObjectProtocol?
    private var watchesToggle = false // armed by the first start(), when the tunables are active
    private weak var activePage: AgentPaneView?
    private var selectionGeneration = 0
    private var pendingAction: SelectionAction = .send
    /// The native pick in progress; nil whenever the pointer is over a page or no pick runs.
    private var native: NativeHover?
    /// How the native outline draws (the gallery compares the others).
    var highlightLook: UIInspectorHighlightView.Look = .outline

    /// The element under the pointer and its containers outward (`elements`), the one shown (`level`), its
    /// outline, and a hold that keeps a right-clicked element through the move back from its menu.
    private struct NativeHover {
        weak var window: NSWindow?
        var elements: [UIInspectorNativeElement]
        var level = 0
        var highlight: OverlayHandle?
        var outline: UIInspectorHighlightView?
        var hold: (point: NSPoint, uptime: TimeInterval)?
        var lastPoint: NSPoint?
        var current: UIInspectorNativeElement? { elements.indices.contains(level) ? elements[level] : nil }
    }

    private enum SelectionAction { case send, copy }

    init(services: AppServices) {
        self.services = services
        inspectNotification = NotificationCenter.default.addObserver(
            forName: .cmuxNextInspectUIElement, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.inspectFromContextMenu() }
        }
    }

    // AppKit monitor removal is main-thread-only. The controller can be
    // released from an action task, so keep deinit nonisolated and perform the
    // cleanup only when the runtime is already on the main thread.
    nonisolated deinit {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { // main-proof: the guard above returns unless Thread.isMainThread.
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let inspectNotification { NotificationCenter.default.removeObserver(inspectNotification) }
        }
    }

    var isPicking: Bool { monitor != nil }
    /// The native element the outline is on now (tests and the debug read).
    var nativeCurrent: UIInspectorNativeElement? { native?.current }

    func toggle() {
        guard AgentPaneTunables.pointerInspector.value else { return }
        if isPicking { stop(); return }
        start()
    }

    /// Starts the picker on the element under the latest right-click in an app-owned
    /// page (the page whose menu opened last), never the one under the chosen menu row:
    /// the page records it on `contextmenu` and holds it through a short grace (picker.ts).
    /// No app-wide right-click monitor runs. The web equivalent of DevTools' Inspect Element.
    func inspectFromContextMenu() {
        guard AgentPaneTunables.pointerInspector.value else { return }
        start()
        inspectWebMenuTarget()
    }

    /// The right-click menu's Point at Element: `menu` names which menu it was picked from. The chat page's (or an
    /// unnamed one) starts on the page's right-clicked element; a native tab's, pane's, workspace row's or sidebar
    /// item's starts on that object, found by its identifier in the key window (one walk of its views, at the pick).
    func inspectFromContextMenu(menu: ActionMenuContext?, target: ActionTargetRef?) {
        guard let menu, menu != .agentChat, let target else { inspectFromContextMenu(); return }
        guard AgentPaneTunables.pointerInspector.value else { return }
        start()
        guard let window = services?.windows.active?.window ?? NSApp.keyWindow,
              let element = UIInspectorNativeElement.find(target, in: window) else { return }
        let outward = UIInspectorNativeElement.elements(at: NSPoint(x: element.frame.midX, y: element.frame.midY), in: window)
        let from = outward.firstIndex { $0.identifier == element.identifier } ?? outward.endIndex
        showNative([element] + outward.suffix(from: min(from + 1, outward.endIndex)), in: window,
                   hold: (NSEvent.mouseLocation, ProcessInfo.processInfo.systemUptime))
    }

    private func inspectWebMenuTarget() {
        let candidates = services.map { Array($0.agentTabs.views.values) } ?? []
        let menus = candidates.compactMap { page in page.lastContextMenu.map { (page: page, menu: $0) } }
        guard let latest = menus.max(by: { $0.menu.uptime < $1.menu.uptime }),
              latest.page.window?.isVisible == true else { return }
        let menuPage = latest.page, point = latest.menu.point
        activate(menuPage)
        menuPage.evaluateUiPointer(pointerScript("inspectMenuTarget", point: point, page: menuPage))
    }

    private func start() {
        guard monitor == nil else { return }
        if !watchesToggle {
            watchesToggle = true
            AgentPaneTunables.whenPointerInspectorTurnsOff { [weak self] in self?.stop() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            guard Thread.isMainThread else { return event } // main-proof: AppKit local monitors are delivered on the main thread
            return self.handle(event, window: self.shellWindow(for: event.window), point: self.screenPoint(of: event))
        }
    }

    private func stop() {
        selectionGeneration &+= 1
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        deactivatePage()
        clearNative()
    }

    /// One picker event in `window` at `point` (screen points; the monitor passes the event's
    /// own): over an app-owned web page it drives the page's own picker; anywhere else (native
    /// UI) it returns `event` untouched.
    func handle(_ event: NSEvent, window: NSWindow?, point: NSPoint?) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 { stop(); return nil }
        if event.type == .keyDown { return nativeKey(event) }
        guard services != nil, let window, let point else { deactivatePage(); return event }
        guard let page = page(at: point, in: window) else {
            deactivatePage()
            return handleNative(event, window: window, point: point)
        }
        clearNative()
        activate(page)
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            pendingAction = event.type == .rightMouseDown ? .copy : .send
            page.evaluateUiPointer(pointerScript("pick", point: point, page: page))
            return nil
        }
        return event
    }

    private func activate(_ page: AgentPaneView) {
        guard activePage !== page else { return }
        deactivatePage()
        activePage = page
        page.uiPointerReport = { [weak self, weak page] value in self?.pageReport(value, from: page) }
        page.setUiPointerInspector(true)
    }

    private func pointerScript(_ operation: String, point: NSPoint, page: AgentPaneView) -> String {
        let local = page.convert(page.window?.convertPoint(fromScreen: point) ?? .zero, from: nil)
        let scale = max(page.uiPointerPageZoom, 0.01)
        let x = local.x / scale
        let y = (page.bounds.height - local.y) / scale
        return "globalThis.__cmuxUiPointer?.\(operation)(\(x), \(y));"
    }

    private func shellWindow(for eventWindow: NSWindow?) -> NSWindow? {
        if let eventWindow, let parent = eventWindow.parent { return parent }
        return eventWindow ?? services?.windows.active?.window
    }

    private func deactivatePage() {
        activePage?.setUiPointerInspector(false)
        activePage?.uiPointerReport = nil
        activePage = nil
    }

    private func screenPoint(of event: NSEvent) -> NSPoint? {
        guard let eventWindow = event.window else { return NSEvent.mouseLocation }
        return eventWindow.convertPoint(toScreen: event.locationInWindow)
    }

    private func page(at point: NSPoint, in window: NSWindow) -> AgentPaneView? {
        services?.agentTabs.views.values.first { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let rect = view.convert(view.bounds, to: nil)
            return rect.contains(window.convertPoint(fromScreen: point))
        }
    }

    // MARK: Native UI

    /// A move outlines the element under `point` (screen); a press picks it (left: to the chat, right: copied) and
    /// is the picker's, not the view's. Anything else goes on.
    private func handleNative(_ event: NSEvent, window: NSWindow, point: NSPoint) -> NSEvent? {
        switch event.type {
        case .mouseMoved:
            hoverNative(at: point, in: window)
            return event
        case .leftMouseDown, .rightMouseDown:
            hoverNative(at: point, in: window, releasingHold: true)
            guard let element = native?.current else { return event }
            selectNative(element, in: window, action: event.type == .rightMouseDown ? .copy : .send)
            return nil
        default:
            return event
        }
    }

    private func hoverNative(at point: NSPoint, in window: NSWindow, releasingHold: Bool = false) {
        if var held = native, let hold = held.hold, held.window === window, !releasingHold {
            // The right-clicked element holds while the pointer comes back from its menu.
            let moved = hypot(point.x - hold.point.x, point.y - hold.point.y)
            if moved < Self.holdSlop || ProcessInfo.processInfo.systemUptime - hold.uptime < Self.holdGrace { return }
            held.hold = nil
            native = held
        }
        if native?.window === window, native?.lastPoint == point, native?.hold == nil { return }
        let windowPoint = window.convertPoint(fromScreen: point)
        let elements = UIInspectorNativeElement.elements(at: windowPoint, in: window) { $0 is UIInspectorHighlightView }
        showNative(elements, in: window, hold: nil)
        native?.lastPoint = point
    }

    /// Outlines `elements[0]` in `window`, reusing the outline when it is already there.
    private func showNative(_ elements: [UIInspectorNativeElement], in window: NSWindow, hold: (point: NSPoint, uptime: TimeInterval)?) {
        guard let first = elements.first else { clearNative(); return }
        if var hover = native, hover.window === window {
            let same = hover.current == first && hover.level == 0
            hover.elements = elements
            hover.level = 0
            hover.hold = hold ?? hover.hold
            native = hover
            if !same { placeOutline() }
            return
        }
        clearNative()
        native = NativeHover(window: window, elements: elements, hold: hold)
        placeOutline()
    }

    private func placeOutline() {
        guard var hover = native, let window = hover.window, let element = hover.current else { return }
        let rect = UIInspectorHighlightView.frame(around: element.frame, in: window)
        if let outline = hover.outline, let highlight = hover.highlight, !highlight.isDismissed {
            outline.show(element, look: highlightLook, outlineIn: rect, around: element.frame)
            highlight.update(anchor: rect)
            return
        }
        let outline = UIInspectorHighlightView(frame: NSRect(origin: .zero, size: rect.size))
        outline.show(element, look: highlightLook, outlineIn: rect, around: element.frame)
        hover.outline = outline
        hover.highlight = WindowOverlayHost.host(for: window).present(outline, options: OverlayOptions(
            kind: .attached, anchor: rect, passesThroughClicks: true))
        native = hover
    }

    private func clearNative() {
        native?.highlight?.dismiss()
        native = nil
    }

    /// Up walks out to the outlined element's container, Down back in, Return picks it. Other keys go on.
    private func nativeKey(_ event: NSEvent) -> NSEvent? {
        guard var hover = native, let window = hover.window else { return event }
        switch event.keyCode {
        case 126: hover.level = min(hover.level + 1, hover.elements.count - 1)
        case 125: hover.level = max(hover.level - 1, 0)
        case 36, 76:
            if let element = hover.current { selectNative(element, in: window, action: .send) }
            return nil
        default: return event
        }
        hover.hold = nil
        native = hover
        placeOutline()
        return nil
    }

    private func selectNative(_ element: UIInspectorNativeElement, in window: NSWindow, action: SelectionAction) {
        let path = native?.elements ?? [element]
        let text = element.report(path: path)
        selectionGeneration &+= 1
        let generation = selectionGeneration
        // The capture must not show the outline.
        clearNative()
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, let services = self.services, self.selectionGeneration == generation else { return }
            let image = try? await AppWindowImage(services: services).capture(window)
            guard self.selectionGeneration == generation else { return }
            let png = image.flatMap { Self.crop($0, rect: element.frame, window: window) }
            self.finish(action: action, name: "UI: \(element.title)", text: text, png: png, preferred: nil)
            self.stop()
        }
    }

    /// How far (points) and how long (seconds) a right-clicked element holds against the pointer.
    private static let holdSlop: CGFloat = 24
    private static let holdGrace: TimeInterval = 0.35

    private static func crop(_ image: CGImage, rect: NSRect, window: NSWindow) -> Data? {
        let scale = Double(image.width) / max(Double(window.frame.width), 1)
        let cut = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                         width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !cut.isEmpty, let cropped = image.cropping(to: cut) else { return nil }
        return png(cropped)
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func pageReport(_ value: JSONValue, from page: AgentPaneView?) {
        guard isPicking, let page, page === activePage else { return }
        guard let object = value.foundationObject as? [String: Any], object["cancelled"] as? Bool != true else { stop(); return }
        let action = pendingAction
        pendingAction = .send
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let name = (object["component"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (object["tag_name"] as? String ?? "webview element")
        let source = object["source_location"] as? String ?? "unavailable"
        let text = [
            "cmux NEXT app-owned webview selection",
            "Component: \(name)",
            "Source: \(source)",
            "Selector: \(object["selector"] as? String ?? "unavailable")",
            "Text: \((object["text_content"] as? String ?? "").prefix(2000))",
            "Computed styles: \(object["computed_styles"] ?? [:])",
            "DOM: \((object["dom_snippet"] as? String ?? "").prefix(2400))",
        ].joined(separator: "\n")
        Task { @MainActor [weak self, weak page] in
            guard let self, let page, self.selectionGeneration == generation else { return }
            // Await the page-side stop so its queued script removes the listener and outline
            // before the snapshot begins; a fire-and-forget evaluate would race the capture.
            _ = try? await page.callPageScript("globalThis.__cmuxUiPointer?.stop?.(); return true;")
            let image = await page.pageSnapshot()
            guard self.selectionGeneration == generation else { return }
            let png = image.flatMap { Self.cropWeb($0, value: object) }
            self.finish(action: action, name: "UI: \(name)", text: text, png: png, preferred: page)
            self.stop()
        }
    }

    private func finish(action: SelectionAction, name: String, text: String, png: Data?, preferred: AgentPaneView?) {
        if action == .copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if let png { NSPasteboard.general.setData(png, forType: .png) }
        } else {
            deliver(name: name, text: text, png: png, preferred: preferred)
        }
    }

    private func deliver(name: String, text: String, png: Data?, preferred: AgentPaneView?) {
        guard let services else { return }
        let target = preferred ?? services.agentTabs.views.values.first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        guard let target else { return }
        AgentPaneDesignSelection(id: "ui-pointer-" + UUID().uuidString, name: name, text: text, png: png).push(to: target)
    }

    private static func cropWeb(_ image: NSImage, value: [String: Any]) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let bounds = value["bounds"] as? [String: Any],
              let x = bounds["x"] as? NSNumber, let y = bounds["y"] as? NSNumber,
              let width = bounds["width"] as? NSNumber, let height = bounds["height"] as? NSNumber,
              let viewport = value["viewport"] as? [String: Any], let viewportWidth = viewport["width"] as? NSNumber,
              let viewportHeight = viewport["height"] as? NSNumber, viewportWidth.doubleValue > 0, viewportHeight.doubleValue > 0 else { return nil }
        let scaleX = Double(cg.width) / viewportWidth.doubleValue
        let scaleY = Double(cg.height) / viewportHeight.doubleValue
        let rect = CGRect(x: x.doubleValue * scaleX,
                          y: y.doubleValue * scaleY,
                          width: width.doubleValue * scaleX, height: height.doubleValue * scaleY).integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let cut = cg.cropping(to: rect), !rect.isEmpty else { return nil }
        return png(cut)
    }
}

/// One piece of cmux's native UI as Point at Element names it: what it is, what it says, where it is (window
/// coordinates) and how a test or the agent finds it again (its accessibility identifier).
struct UIInspectorNativeElement: Equatable {
    enum Kind: String {
        case tab = "Tab", tabStrip = "Tab bar", pane = "Pane", paneToolbar = "Pane toolbar"
        case workspace = "Workspace", sidebarItem = "Sidebar item", control = "Control", view = "View"
    }

    var kind: Kind
    var title: String
    var identifier: String?
    var frame: NSRect
    var role: String?
    var viewType: String

    /// The elements under `point` (window coordinates), innermost first. One hit-test and one walk up its
    /// superviews, run only on a picking move; `skip` passes over the picker's own views.
    static func elements(at point: NSPoint, in window: NSWindow, skip: (NSView) -> Bool = { _ in false }) -> [Self] {
        guard let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point) else { return [] }
        var chain: [NSView] = []
        var next: NSView? = hit
        while let view = next {
            if !skip(view) { chain.append(view) }
            if view === content { break }
            next = view.superview
        }
        let inPane = chain.contains { $0.accessibilityIdentifier().hasPrefix(Prefix.pane) }
        var found: [Self] = []
        for view in chain {
            let identifier = view.accessibilityIdentifier()
            if identifier == Prefix.strip, let tab = tab(in: view, containing: window.convertPoint(toScreen: point), window: window) {
                found.append(tab)
            }
            guard let element = element(for: view, identifier: identifier, inPane: inPane) else { continue }
            // A control and the view it wraps can share a frame; keep the outer, named one.
            if let last = found.last, last.frame == element.frame, last.kind == .control || last.kind == .view {
                found.removeLast()
            }
            found.append(element)
        }
        return found
    }

    /// The menu target's element in `window` (a native menu run carries no point): one walk of the views for its
    /// identifier.
    static func find(_ target: ActionTargetRef, in window: NSWindow) -> Self? {
        guard let content = window.contentView else { return nil }
        switch target.kind {
        case .tab:
            guard let strip = descendant(of: content, where: { $0.accessibilityIdentifier() == Prefix.strip && !$0.isHiddenOrHasHiddenAncestor }) else { return nil }
            let wanted = Prefix.tab + target.id
            guard let child = (strip.accessibilityChildren() ?? []).first(where: { ($0 as? NSAccessibilityElement)?.accessibilityIdentifier() == wanted }) as? NSAccessibilityElement
            else { return nil }
            return tab(child, window: window)
        case .pane, .workspace, .sidebarItem:
            let prefix = target.kind == .pane ? Prefix.pane : target.kind == .workspace ? Prefix.workspace : Prefix.item
            let wanted = prefix + target.id
            guard let view = descendant(of: content, where: { $0.accessibilityIdentifier() == wanted && !$0.isHiddenOrHasHiddenAncestor })
            else { return nil }
            return element(for: view, identifier: wanted, inPane: false)
        default:
            return nil
        }
    }

    /// The text the agent gets: what it is, how to find it, where it sits, and what holds it.
    func report(path: [Self]) -> String {
        var lines = ["cmux native UI element", "\(kind.rawValue): \(title)"]
        if let identifier { lines.append("accessibility identifier: \(identifier)") }
        if let role { lines.append("accessibility role: \(role)") }
        lines.append("view: \(viewType)")
        lines.append(String(format: "window frame: x %.0f y %.0f w %.0f h %.0f (bottom-left origin)",
                            frame.minX, frame.minY, frame.width, frame.height))
        let outer = path.drop { $0 != self }.dropFirst()
        if !outer.isEmpty { lines.append("inside: " + outer.map { "\($0.kind.rawValue) \"\($0.title)\"" }.joined(separator: " > ")) }
        return lines.joined(separator: "\n")
    }

    enum Prefix {
        static let strip = "cmux.tabs.strip"
        static let tab = "cmux.tabs.tab."
        static let pane = "cmux.layout.pane."
        static let workspace = "cmux.sidebar.workspace."
        static let item = "cmux.sidebar.item."
        static let toolbar = "cmux.pane.toolbar."
        static let nativeToolbar = "cmux.pane.native-toolbar."
    }

    private static func element(for view: NSView, identifier: String, inPane: Bool) -> Self? {
        let kind: Kind
        switch identifier {
        case let id where id.hasPrefix(Prefix.pane): kind = .pane
        case let id where id.hasPrefix(Prefix.workspace): kind = .workspace
        case let id where id.hasPrefix(Prefix.item): kind = .sidebarItem
        case let id where id.hasPrefix(Prefix.toolbar) || id.hasPrefix(Prefix.nativeToolbar): kind = .paneToolbar
        case Prefix.strip: kind = .tabStrip
        case let id where id.hasPrefix("cmux."): kind = .control
        default:
            // Inside a pane only cmux's own named views count; a terminal's or page's insides are not ours to name.
            guard !inPane, view.isAccessibilityElement(), label(of: view) != nil else { return nil }
            kind = .control
        }
        return Self(kind: kind, title: label(of: view) ?? kind.rawValue, identifier: identifier.isEmpty ? nil : identifier,
                    frame: view.convert(view.bounds, to: nil), role: view.accessibilityRole()?.rawValue,
                    viewType: String(describing: type(of: view)))
    }

    /// Tabs are layer cells, not views: the strip names each as an accessibility child (screen frames).
    private static func tab(in strip: NSView, containing screenPoint: NSPoint, window: NSWindow) -> Self? {
        let children = (strip.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        guard let hit = children.first(where: { $0.accessibilityFrame().contains(screenPoint) }) else { return nil }
        return tab(hit, window: window)
    }

    private static func tab(_ element: NSAccessibilityElement, window: NSWindow) -> Self {
        let identifier = element.accessibilityIdentifier()
        let title = element.accessibilityLabel() ?? element.accessibilityTitle() ?? Kind.tab.rawValue
        return Self(kind: identifier.hasSuffix(".close") ? .control : .tab, title: title, identifier: identifier,
                    frame: window.convertFromScreen(element.accessibilityFrame()),
                    role: element.accessibilityRole()?.rawValue, viewType: String(describing: type(of: element)))
    }

    private static func label(of view: NSView) -> String? {
        let text = view.accessibilityLabel() ?? view.accessibilityTitle() ?? (view as? NSControl)?.stringValue
        return text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func descendant(of view: NSView, where match: (NSView) -> Bool) -> NSView? {
        var queue = [view]
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            if match(next) { return next }
            queue.append(contentsOf: next.subviews)
        }
        return nil
    }
}

/// The outline over the native element being pointed at, with a chip naming it ("Tab · notes.md"). It never
/// takes the mouse; one is reused for the whole pick.
@MainActor
final class UIInspectorHighlightView: NSView {
    /// How the outline draws: `outline` (tint and 2pt ring, the default), `filled` (a stronger tint), `brackets`
    /// (corner marks only, the content stays clear).
    enum Look: String, CaseIterable { case outline, filled, brackets }

    private(set) var look: Look = .outline
    private(set) var chip = ""
    private var box = NSRect.zero

    static let chipHeight: CGFloat = 18

    /// The overlay's frame for an element at `frame` (window coordinates): the element plus the chip, above it
    /// when there is room, else below.
    static func frame(around frame: NSRect, in window: NSWindow) -> NSRect {
        let height = window.contentView?.bounds.height ?? window.frame.height
        let ring = frame.insetBy(dx: -2, dy: -2)
        let above = ring.maxY + chipHeight + 2 <= height
        let chip = NSRect(x: ring.minX, y: above ? ring.maxY + 2 : ring.minY - chipHeight - 2,
                          width: max(ring.width, 160), height: chipHeight)
        return ring.union(chip)
    }

    func show(_ element: UIInspectorNativeElement, look: Look, outlineIn rect: NSRect, around frame: NSRect) {
        self.look = look
        chip = "\(element.kind.rawValue) · \(element.title)"
        box = frame.insetBy(dx: -2, dy: -2).offsetBy(dx: -rect.minX, dy: -rect.minY)
        setFrameSize(rect.size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor.systemBlue
        switch look {
        case .outline:
            blue.withAlphaComponent(0.15).setFill()
            box.fill()
            let ring = NSBezierPath(rect: box.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            blue.setStroke()
            ring.stroke()
        case .filled:
            blue.withAlphaComponent(0.32).setFill()
            box.fill()
            blue.setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        case .brackets:
            let arm = min(10, box.width / 3, box.height / 3)
            let path = NSBezierPath()
            let r = box.insetBy(dx: 1, dy: 1)
            for (corner, dx, dy) in [(NSPoint(x: r.minX, y: r.minY), arm, arm), (NSPoint(x: r.maxX, y: r.minY), -arm, arm),
                                     (NSPoint(x: r.minX, y: r.maxY), arm, -arm), (NSPoint(x: r.maxX, y: r.maxY), -arm, -arm)] {
                path.move(to: NSPoint(x: corner.x + dx, y: corner.y))
                path.line(to: corner)
                path.line(to: NSPoint(x: corner.x, y: corner.y + dy))
            }
            path.lineWidth = 2.5
            blue.setStroke()
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: chip, attributes: attributes)
        let above = box.maxY + 2 + Self.chipHeight <= bounds.height + 0.5
        let width = min(ceil(text.size().width) + 12, bounds.width)
        let pill = NSRect(x: box.minX, y: above ? box.maxY + 2 : box.minY - Self.chipHeight - 2, width: width, height: Self.chipHeight)
        blue.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        text.draw(with: pill.insetBy(dx: 6, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
