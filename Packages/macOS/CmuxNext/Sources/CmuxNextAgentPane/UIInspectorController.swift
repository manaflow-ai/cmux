public import AppKit
public import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings

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
public final class UIInspectorController {
    /// What the picker needs from the app: its agent chat pages, the active shell window, and a window capture.
    public struct Host {
        public var pages: @MainActor () -> [AgentPaneView]
        public var activeWindow: @MainActor () -> NSWindow?
        public var capture: @MainActor (NSWindow) async -> CGImage?

        public init(pages: @escaping @MainActor () -> [AgentPaneView], activeWindow: @escaping @MainActor () -> NSWindow?,
                    capture: @escaping @MainActor (NSWindow) async -> CGImage?) {
            self.pages = pages
            self.activeWindow = activeWindow
            self.capture = capture
        }
    }

    private let host: Host
    /// The picker's monitor, installed only between `start()` and `stop()`.
    private var monitor: Any?
    private var inspectNotification: NSObjectProtocol?
    private var watchesToggle = false // armed by the first start(), when the tunables are active
    private weak var activePage: AgentPaneView?
    private var selectionGeneration = 0
    private var pendingAction: SelectionAction = .send
    private var nativeSelecting = false // a native pick is capturing: events are held until it lands
    private var swallowsRelease = false // the picker took the press, so the release is its too
    /// The native pick: empty until a pick's first move over native UI, cleared by `stop()`.
    public let native = UIPointerNativePicker()

    private enum SelectionAction { case send, copy }

    public init(host: Host) {
        self.host = host
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

    public var isPicking: Bool { monitor != nil }

    public func toggle() {
        guard AgentPaneTunables.pointerInspector.value else { return }
        if isPicking { stop(); return }
        start()
    }

    /// Starts the picker on the element under the latest right-click in an app-owned
    /// page (the page whose menu opened last), never the one under the chosen menu row:
    /// the page records it on `contextmenu` and holds it through a short grace (picker.ts).
    /// No app-wide right-click monitor runs. The web equivalent of DevTools' Inspect Element.
    public func inspectFromContextMenu() {
        guard AgentPaneTunables.pointerInspector.value else { return }
        start()
        inspectWebMenuTarget()
    }

    /// The right-click menu's Point at Element: `menu` names which menu it was picked from. The chat page's (or an
    /// unnamed one) starts on the page's right-clicked element; a native tab's, pane's, workspace row's or sidebar
    /// item's starts on that object, found by its identifier in the key window (one walk of its views, at the pick).
    public func inspectFromContextMenu(menu: ActionMenuContext?, target: ActionTargetRef?) {
        guard let menu, menu != .agentChat, let target else { inspectFromContextMenu(); return }
        guard AgentPaneTunables.pointerInspector.value else { return }
        start()
        guard let window = host.activeWindow() ?? NSApp.keyWindow else { return }
        native.start(on: target, in: window)
    }

    private func inspectWebMenuTarget() {
        let candidates = host.pages()
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            guard Thread.isMainThread else { return event } // main-proof: AppKit local monitors are delivered on the main thread
            return self.handle(event, window: self.shellWindow(for: event.window), point: self.screenPoint(of: event))
        }
    }

    private func stop() {
        selectionGeneration &+= 1
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        nativeSelecting = false
        swallowsRelease = false
        deactivatePage()
        native.clear()
    }

    /// One picker event in `window` at `point` (screen points; the monitor passes the event's
    /// own): over an app-owned web page it drives the page's own picker; anywhere else (native
    /// UI) it returns `event` untouched.
    public func handle(_ event: NSEvent, window: NSWindow?, point: NSPoint?) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 { stop(); return nil }
        // A native pick is being captured: nothing reaches the views and nothing outlines until it lands.
        if nativeSelecting { return event.type == .mouseMoved ? event : nil }
        if event.type == .leftMouseUp || event.type == .rightMouseUp {
            // The release of a press the picker took is the picker's too.
            defer { swallowsRelease = false }
            return swallowsRelease ? nil : event
        }
        if event.type == .keyDown { return nativeKey(event) }
        guard let window, let point else { deactivatePage(); return event }
        guard let page = page(at: point, in: window) else {
            deactivatePage()
            return handleNative(event, window: window, point: point)
        }
        native.clear()
        activate(page)
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            pendingAction = event.type == .rightMouseDown ? .copy : .send
            swallowsRelease = true
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
        return eventWindow ?? host.activeWindow()
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
        host.pages().first { view in
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
            native.hover(at: point, in: window)
            return event
        case .leftMouseDown, .rightMouseDown:
            // While picking a press is the picker's, even over nothing it names.
            native.hover(at: point, in: window, releasingHold: true)
            swallowsRelease = true
            if let element = native.current {
                selectNative(element, in: window, action: event.type == .rightMouseDown ? .copy : .send)
            }
            return nil
        default:
            return event
        }
    }

    /// Up and Down walk the outline out and in, Return picks it; other keys (and any with a modifier) go on.
    private func nativeKey(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return event }
        switch native.key(event.keyCode) {
        case .pass: return event
        case .handled: return nil
        case .pick(let element):
            if let window = native.window { selectNative(element, in: window, action: .send) }
            return nil
        }
    }

    private func selectNative(_ element: UIPointerNativeElement, in window: NSWindow, action: SelectionAction) {
        let text = element.report(path: native.path)
        selectionGeneration &+= 1
        let generation = selectionGeneration
        native.clear() // the capture must not show the outline
        nativeSelecting = true
        Task { [weak self, weak window] in
            guard let self, self.selectionGeneration == generation else { return }
            // A window gone mid-capture ends the pick; otherwise the capture would hold every event until Esc.
            guard let window else { self.stop(); return }
            let image = await self.host.capture(window)
            guard self.selectionGeneration == generation else { return }
            let png = image.flatMap { UIPointerNativePicker.crop($0, rect: element.frame, window: window) }
            // The pick goes to a chat in the window it was made in, not the first chat of any window.
            let page = self.host.pages().first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            self.finish(action: action, name: "UI: \(element.title)", text: text, png: png, preferred: page)
            self.stop()
        }
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
        let target = preferred ?? host.pages().first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
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
        return UIPointerNativePicker.png(cut)
    }
}
