import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import QuartzCore

/// One drag, every destination (plans/cmux-next/REWRITE.md "Tab drag").
///
/// Takes over a tab or a whole tab group that left its strip, or sidebar
/// workspaces that left their sidebar (`TabDragSession+Workspaces`). A floating
/// ghost follows the pointer across every window and outside them; over a
/// strip it folds into an inline tab (the strip opens a gap), elsewhere it
/// is a glass preview card. Every `TabDropTargetProviding` in every window
/// (sidebar, strips, layout) is asked by screen point, in that priority.
/// Release commits ONE daemon command for the outcome with a client
/// transaction; release outside every window tears off into a new window
/// under the pointer; Escape springs back. `TabDragLifecycle` guarantees
/// every drag ends and the source strip gets its tab back unless it moved.
///
/// A display link runs only while the ghost animates or a columns screen
/// auto-scrolls, and is invalidated when the drag ends.
final class TabDragSession: NSObject {
    unowned let services: AppServices
    var drag: Drag?
    /// Ghost of the previous drag still flying home or into its slot.
    var landing: Drag?
    var resignObserver: (any NSObjectProtocol)?

    init(services: AppServices) {
        self.services = services
        super.init()
    }

    var isDragging: Bool { drag != nil }

    // MARK: Begin

    func begin(_ start: TabDragStart, from pane: PaneController) {
        let item = Item.tab(start.tabID.rawValue)
        let payload = TabDragPayload.tab(id: start.tabID.rawValue, sourceStripID: start.stripID)
        begin(item: item, payload: payload, frame: start.screenFrame, grabOffset: start.grabOffset, point: start.screenPoint,
              image: start.snapshot?.cgImage, previewTab: start.tabID.rawValue, draggedCount: 1, pane: pane)
    }

    func beginGroup(_ start: TabGroupDragStart, from pane: PaneController) {
        let item = Item.group(start.groupID, members: start.tabIDs.map(\.rawValue))
        let payload = TabDragPayload.tabGroup(id: start.groupID.rawValue, tabIDs: start.tabIDs.map(\.rawValue),
                                              sourceStripID: start.stripID, width: start.screenFrame.width)
        let preview = pane.stripModel.selectedID.flatMap { start.tabIDs.contains($0) ? $0.rawValue : nil } ?? start.tabIDs.first?.rawValue
        begin(item: item, payload: payload, frame: start.screenFrame, grabOffset: start.grabOffset, point: start.screenPoint,
              image: start.snapshot?.cgImage, previewTab: preview, draggedCount: start.tabIDs.count, pane: pane)
    }

    /// `pane` is the source strip's pane (tab items); workspace items have
    /// no pane and name their source `window`.
    func begin(item: Item, payload: TabDragPayload?, frame: CGRect, grabOffset: CGPoint, point: CGPoint, image: CGImage?,
               previewTab: String?, draggedCount: Int, pane: PaneController?, window sourceWindow: WindowController? = nil) {
        if drag != nil { finish(commit: false) }
        finishLanding()

        let window = sourceWindow ?? services.windows.controllers.first { $0.content === pane?.workspace }
        var context = pane.map { Self.context(of: $0, draggedCount: draggedCount) } ?? .workspaces(count: draggedCount)
        if let window { context.sourceWindowWorkspaceCount = max(1, services.windows.registry.members(of: window.state.id).count) }
        let content = pane?.view.bounds ?? window?.content?.layoutView?.bounds ?? .zero
        let aspect = content.width > 0 ? (content.height - Metrics.tabStripHeight) / content.width : nil
        let scale = window?.window?.backingScaleFactor ?? 2
        let ghost = TabDragGhostPanel(tabImage: image, tabSize: frame.size, aspect: aspect, scale: scale)
        let motion = TabDragGhostMotion(rect: frame, cardness: 0, reduceMotion: !Motion.animatesMovement,
                                        rectSpring: Motion.spring(.track), morphSpring: Motion.spring(.appear))
        let windowFrame = window?.window?.frame ?? .zero
        let source = Source(
            item: item, payload: payload, pane: pane, window: window, screenFrame: frame, grabOffset: grabOffset,
            tabOffset: CGPoint(x: frame.minX - windowFrame.minX, y: windowFrame.maxY - frame.maxY),
            windowSize: windowFrame.size, context: context
        )
        let lifecycle = TabDragLifecycle { [weak pane] in
            guard let pane else { return }
            switch item {
            case .tab(let id): pane.view.stripView.restoreDetachedTab(StripTabID(id))
            case .group(let id, _): pane.view.stripView.restoreDetachedGroup(id)
            case .workspaces: return
            }
            pane.resyncStrip()
        }
        let drag = Drag(source: source, lifecycle: lifecycle, ghost: ghost, motion: motion, point: point)
        drag.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(commit: false) }
        }
        self.drag = drag
        focusDragBegan(item, from: pane)
        ghost.show()
        drag.link = ghost.makeDisplayLink(target: self, selector: #selector(tick(_:)))
        drag.link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        drag.link?.add(to: .main, forMode: .common)
        update(point)
        loadThumbnail(previewTab, into: drag)
    }

    func loadThumbnail(_ tab: String?, into drag: Drag) {
        guard let tab else { return }
        let cache = services.cache
        Task { [weak drag] in
            let image = await cache?.previewImage(for: tab, maxPixelSize: CGSize(width: 640, height: 640))
            drag?.ghost.setThumbnail(image)
        }
    }

    static func context(of pane: PaneController, draggedCount: Int) -> TabDragContext {
        let workspaceTabs = pane.workspace?.workspace.screens.flatMap(\.panes).reduce(0) { $0 + $1.tabs.count } ?? pane.pane.tabs.count
        return TabDragContext(sourcePaneID: pane.layoutPaneID.rawValue, sourcePaneTabCount: pane.pane.tabs.count,
                              sourceWorkspaceID: pane.workspace?.workspace.id ?? "", sourceWorkspaceTabCount: workspaceTabs,
                              draggedTabCount: draggedCount)
    }

    // MARK: Events

    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDragged:
            update(Self.screenPoint(of: event))
            return nil
        case .leftMouseUp:
            update(Self.screenPoint(of: event))
            finish(commit: true)
            return nil
        case .leftMouseDown:
            // A lost mouse-up (another tracking loop ate it): end safely.
            finish(commit: false)
            return event
        case .keyDown where event.keyCode == 53:
            finish(commit: false)
            return nil
        default:
            return event
        }
    }

    /// The event's own location, so events posted to this process (tests,
    /// automation) work without moving the real cursor.
    static func screenPoint(of event: NSEvent) -> CGPoint {
        if let window = event.window { return window.convertPoint(toScreen: event.locationInWindow) }
        return event.locationInWindow
    }

    // MARK: Hit testing

    func update(_ point: CGPoint) {
        guard let drag else { return }
        drag.point = point
        drag.samplePointer(point, at: CACurrentMediaTime())
        if case .workspaces = drag.source.item { return updateWorkspaces(point, drag: drag) }
        let hit = hitTest(point, drag: drag)
        if let previous = drag.winner, previous.provider !== hit.winner?.provider {
            previous.provider.dropExited()
        }
        drag.winner = hit.winner
        drag.outcome = TabDragResolver.outcome(for: hit.winner?.proposal, insideWindow: hit.window != nil, screenPoint: point,
                                               context: drag.source.context)
        present(drag)
        wake(drag)
    }

    struct Hit {
        var window: WindowController?
        var winner: Winner?
    }

    func hitTest(_ point: CGPoint, drag: Drag) -> Hit {
        guard let controller = window(at: point) else { return Hit() }
        guard let payload = drag.source.payload else { return Hit(window: controller) }
        for provider in providers(in: controller, near: point, drag: drag) {
            guard let proposal = provider.dropHitTest(screenPoint: point, payload: payload) else { continue }
            drag.touched[ObjectIdentifier(provider)] = provider
            if TabDragResolver.accepts(proposal.kind, context: drag.source.context) {
                return Hit(window: controller, winner: Winner(provider: provider, proposal: proposal, window: controller))
            }
            provider.dropExited()
        }
        return Hit(window: controller)
    }

    /// Frontmost app window containing `point`; nil outside all of them.
    func window(at point: CGPoint) -> WindowController? {
        let controllers = services.windows.controllers
        for window in NSApp.orderedWindows where window.isVisible && !window.isMiniaturized && window.frame.contains(point) {
            if let controller = controllers.first(where: { $0.window === window }) { return controller }
        }
        return nil
    }

    /// Drop targets of `controller` in priority order: sidebar, the strips
    /// near the point, then the layout.
    func providers(in controller: WindowController, near point: CGPoint, drag: Drag) -> [any TabDropTargetProviding] {
        let adapters = self.adapters(for: controller, drag: drag)
        var list: [any TabDropTargetProviding] = [adapters.sidebar]
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            let strip = pane.view.stripView
            guard let window = strip.window, !strip.isHiddenOrHasHiddenAncestor else { continue }
            let frame = window.convertToScreen(strip.convert(strip.bounds, to: nil)).insetBy(dx: 0, dy: -Metrics.space4)
            if frame.contains(point) { list.append(strip) }
        }
        list.append(adapters.layout)
        return list
    }

    /// The window's sidebar and layout drop adapters, cached for the drag.
    func adapters(for controller: WindowController, drag: Drag) -> (sidebar: SidebarTabDropTarget, layout: LayoutTabDropTarget) {
        let key = ObjectIdentifier(controller)
        let adapters = drag.adapters[key] ?? (SidebarTabDropTarget(bridge: controller.sidebar), LayoutTabDropTarget(window: controller))
        drag.adapters[key] = adapters
        return adapters
    }

}
