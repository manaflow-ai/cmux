import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
import ImageIO
import UniformTypeIdentifiers

/// Inspect Element for cmux NEXT's own web content: the HTML/React pages the
/// app hosts (an agent chat, `AgentPaneView`). Native AppKit/SwiftUI views are
/// never inspectable and pay nothing: no monitor runs until the picker starts,
/// and while it runs an event over a native view goes on untouched (no
/// hit-test, no highlight, no swallowed click).
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

    func toggle() {
        guard AgentPaneTunables.pointerInspector.value else { return }
        if isPicking { stop(); return }
        start()
    }

    /// Starts the picker and highlights the element under the most recent
    /// right-click in an app-owned web page (the page whose menu opened last).
    /// The page records that point itself, so no app-wide right-click monitor
    /// runs. The web equivalent of DevTools' Inspect Element.
    func inspectFromContextMenu() {
        guard AgentPaneTunables.pointerInspector.value else { return }
        start()
        let candidates = services.map { Array($0.agentTabs.views.values) } ?? []
        let menus = candidates.compactMap { page in page.lastContextMenu.map { (page: page, menu: $0) } }
        guard let latest = menus.max(by: { $0.menu.uptime < $1.menu.uptime }),
              latest.page.window?.isVisible == true else { return }
        let menuPage = latest.page, point = latest.menu.point
        activate(menuPage)
        menuPage.evaluateUiPointer(pointerScript("highlight", point: point, page: menuPage))
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
    }

    /// One picker event in `window` at `point` (screen points; the monitor passes the event's
    /// own): over an app-owned web page it drives the page's own picker; anywhere else (native
    /// UI) it returns `event` untouched.
    func handle(_ event: NSEvent, window: NSWindow?, point: NSPoint?) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 { stop(); return nil }
        guard services != nil, let window, let point, let page = page(at: point, in: window) else {
            deactivatePage()
            return event
        }
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

    private func pageReport(_ value: JSONValue, from page: AgentPaneView?) {
        guard isPicking, let page, page === activePage else { return }
        guard let object = value.foundationObject as? [String: Any] else { return }
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
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cut, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
