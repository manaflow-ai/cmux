import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSettings
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Debug/Labs picker for cmux NEXT's own window. A local monitor observes the
/// real event before AppKit dispatches it; the overlay is click-through, so
/// hover never changes the product's hit-testing path.
@MainActor
final class UIInspectorController {
    private weak var services: AppServices?
    private var monitor: Any?
    /// Records the gesture that opened a native or app-owned webview menu. The
    /// menu action then starts the picker at that exact screen point.
    private var contextMonitor: Any?
    private var lastContextPoint: NSPoint?
    private weak var lastContextWindow: NSWindow?
    private var inspectNotification: NSObjectProtocol?
    private var activeWindow: NSWindow?
    private var highlighted: NSView?
    private var highlight: OverlayHandle?
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
        if AgentPaneTunables.pointerInspector.value { installContextMonitor() }
        observeToggle()
    }

    // AppKit monitor removal is main-thread-only. The controller can be
    // released from an action task, so keep deinit nonisolated and perform the
    // cleanup only when the runtime is already on the main thread.
    nonisolated deinit {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { // main-proof: the guard above returns unless Thread.isMainThread.
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let contextMonitor { NSEvent.removeMonitor(contextMonitor) }
            if let inspectNotification { NotificationCenter.default.removeObserver(inspectNotification) }
        }
    }

    var isPicking: Bool { monitor != nil }

    func toggle() {
        guard AgentPaneTunables.pointerInspector.value else { return }
        if isPicking { stop(); return }
        start()
    }

    /// Starts the picker and immediately highlights the element that opened the
    /// most recent app-owned context menu. This is the native equivalent of
    /// browser DevTools' Inspect Element command.
    func inspectFromContextMenu() {
        guard AgentPaneTunables.pointerInspector.value else { return }
        start()
        guard let point = lastContextPoint,
              let window = lastContextWindow,
              window.isVisible else { return }
        highlight(at: point, in: window)
    }

    private func observeToggle() {
        withObservationTracking { _ = AgentPaneTunables.pointerInspector.value } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AgentPaneTunables.pointerInspector.value {
                    self.installContextMonitor()
                } else {
                    self.stop()
                    self.removeContextMonitor()
                }
                self.observeToggle()
            }
        }
    }

    private func installContextMonitor() {
        guard contextMonitor == nil else { return }
        contextMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, let window = self.shellWindow(for: event.window), let point = self.screenPoint(of: event) else { return event }
            self.lastContextPoint = point
            self.lastContextWindow = window
            return event
        }
    }

    private func removeContextMonitor() {
        if let contextMonitor { NSEvent.removeMonitor(contextMonitor) }
        contextMonitor = nil
        lastContextPoint = nil
        lastContextWindow = nil
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            guard Thread.isMainThread else { return event } // main-proof: AppKit local monitors are delivered on the main thread
            return self.handle(event)
        }
    }

    private func stop() {
        selectionGeneration &+= 1
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        deactivatePage()
        highlight?.dismiss()
        highlight = nil
        highlighted = nil
        activeWindow = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 { stop(); return nil }
        guard services != nil, let window = shellWindow(for: event.window), let point = screenPoint(of: event) else { return event }
        activeWindow = window
        if let page = page(at: point, in: window) {
            activate(page)
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                pendingAction = event.type == .rightMouseDown ? .copy : .send
                page.evaluateUiPointer(pointerScript("pick", point: point, page: page))
                return nil
            }
            return event
        }
        deactivatePage()
        guard let content = window.contentView else { return event }
        let local = content.convert(window.convertPoint(fromScreen: point), from: nil)
        guard let view = content.hitTest(local), !isInspectorView(view) else { return event }
        showHighlight(for: view, in: window)
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            selectNative(view, in: window, action: event.type == .rightMouseDown ? .copy : .send)
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

    private func highlight(at point: NSPoint, in window: NSWindow) {
        activeWindow = window
        if let page = page(at: point, in: window) {
            activate(page)
            page.evaluateUiPointer(pointerScript("highlight", point: point, page: page))
            return
        }
        deactivatePage()
        guard let content = window.contentView else { return }
        let local = content.convert(window.convertPoint(fromScreen: point), from: nil)
        guard let view = content.hitTest(local), !isInspectorView(view) else { return }
        showHighlight(for: view, in: window)
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

    private func showHighlight(for view: NSView, in window: NSWindow) {
        let rect = view.convert(view.bounds, to: nil)
        guard !rect.isEmpty else { return }
        if highlighted === view, let highlight { highlight.update(anchor: rect); return }
        highlighted = view
        highlight?.dismiss()
        let outline = UIInspectorHighlightView(frame: NSRect(origin: .zero, size: rect.size))
        highlight = WindowOverlayHost.host(for: window).present(outline, options: OverlayOptions(kind: .attached, anchor: rect, passesThroughClicks: true))
    }

    private func selectNative(_ view: NSView, in window: NSWindow, action: SelectionAction) {
        guard let content = window.contentView else { return }
        let rect = view.convert(view.bounds, to: nil)
        let name = view.accessibilityIdentifier().isEmpty ? String(describing: type(of: view)) : view.accessibilityIdentifier()
        let source = source(for: view)
        let styles = [
            "frame": "\(Int(rect.width))×\(Int(rect.height))",
            "hidden": view.isHidden ? "true" : "false",
            "alpha": String(format: "%.2f", view.alphaValue),
            "cornerRadius": view.layer.map { String(format: "%.1f", $0.cornerRadius) } ?? "0",
            "background": view.layer?.backgroundColor.map { NSColor(cgColor: $0)?.description ?? "set" } ?? "none",
        ]
        let role = view.accessibilityRole()?.rawValue ?? "unavailable"
        let label = view.accessibilityLabel() ?? "unavailable"
        let styleText = styles.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        let text = [
            "cmux NEXT UI pointer selection",
            "View: \(name)",
            "Source: \(source)",
            "Accessibility role: \(role)",
            "Accessibility label: \(label)",
            "Frame (window points): x=\(Int(rect.minX)) y=\(Int(rect.minY)) width=\(Int(rect.width)) height=\(Int(rect.height))",
            "Styles: \(styleText)",
        ].joined(separator: "\n")
        selectionGeneration &+= 1
        let generation = selectionGeneration
        highlight?.dismiss()
        highlight = nil
        highlighted = nil
        Task { @MainActor [weak self, weak window, weak view] in
            guard let self, let window, let view, self.selectionGeneration == generation else { return }
            guard let services = self.services else { return }
            let image = try? await AppWindowImage(services: services).capture(window)
            guard self.selectionGeneration == generation else { return }
            let png = image.flatMap { Self.crop($0, rect: view.convert(view.bounds, to: nil), window: window) }
            self.finish(action: action, name: "UI: \(name)", text: text, png: png, preferred: nil)
            self.stop()
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

    private func source(for view: NSView) -> String {
        let type = String(reflecting: type(of: view)).split(separator: ".").last.map(String.init) ?? "NSView"
        return Self.sourceByViewType[type] ?? "debug view registry: \(type) (source unavailable)"
    }

    /// Stable debug-only source anchors for native views. SwiftUI/AppKit wrappers often erase
    /// their concrete type at runtime, so the registry intentionally reports a stable type name
    /// when a source anchor has not been registered yet.
    private static let sourceByViewType: [String: String] = [
        "AgentPaneView": "CmuxNextAgentPane/AgentPaneView.swift:18",
        "LayoutRootView": "CmuxNextLayout/Views/LayoutRootView.swift:13",
        "SidebarView": "CmuxNextSidebar/Views/SidebarView.swift:21",
        "SidebarContainerView": "CmuxNextSidebar/Views/SidebarContainerView.swift:22",
        "SidebarRowView": "CmuxNextSidebar/Views/SidebarRowView.swift:8",
        "SidebarItemListRowView": "CmuxNextSidebar/Views/SidebarItemListRowView.swift:9",
        "TabStripView": "CmuxNextTabs/TabStripView.swift:15",
        "PaneToolbarView": "CmuxNextTabs/PaneToolbarView.swift:32",
    ]

    private func isInspectorView(_ view: NSView) -> Bool { view is UIInspectorHighlightView }

    private static func crop(_ image: CGImage, rect: NSRect, window: NSWindow) -> Data? {
        let scale = Double(image.width) / max(Double(window.frame.width), 1)
        let cut = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                         width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: cut), !cut.isEmpty else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cropped, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
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

@MainActor
private final class UIInspectorHighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.withAlphaComponent(0.15).setFill()
        dirtyRect.fill()
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
