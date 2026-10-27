import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextInput
import CmuxNextLayout
import CmuxNextSignposts
import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextCompat

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
/// A frame client runs only while the ghost animates or a columns screen
/// auto-scrolls, and is invalidated when the drag ends. With `motion.renderServer`
/// on the ghost's springs run in Core Animation and the client runs only while
/// the pointer auto-scrolls a columns screen or a dwell is armed.
final class TabDragSession: NSObject {
    unowned let services: AppServices
    var drag: Drag?
    /// Ghost of the previous drag still flying home or into its slot.
    var landing: Drag?
    /// The app's resign-active notice ends the drag (``AppEvents``: one observer for the app).
    var resignObserver: EventSubscription?
    /// Takes one `motion.drag_frame` interval per ghost tick (``tick(_:elapsed:)``).
    let motionSignposter: Signposter
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): a drag's moves hit-test on a frame
    /// interval's first move and once more at its frame. Nil: every move hit-tests.
    let moveFrames: FrameInputCoalescers?
    /// Makes a drag's resampler on its start (feature `resampledDrags`): the ghost is drawn at the pointer resampled
    /// at each frame's time. Nil (and without ``moveFrames``): the ghost follows the real pointer.
    let makeResampler: () -> DragResampler?

    /// - Parameters:
    ///   - moveFrames: The app's ``AppServices/dragFrameInput``.
    ///   - makeResampler: The app's ``AppServices/dragResampler`` off under Reduce Motion.
    ///   - motionSignposter: The `motion` category's signposter (the app's: ``Signposter/motion``; tests pass
    ///     one on their own trace runtime).
    init(services: AppServices, moveFrames: FrameInputCoalescers? = nil, makeResampler: @escaping () -> DragResampler? = { nil },
         motionSignposter: Signposter = .motion) {
        self.services = services
        self.moveFrames = moveFrames
        self.makeResampler = makeResampler
        self.motionSignposter = motionSignposter
        super.init()
    }

    var isDragging: Bool { drag != nil }
    /// Commits sent and not yet settled (their presentation is still on).
    var commitsInFlight: Set<ClientTransactionID> = []
    /// A drag, its landing flight, or a commit is in flight: strips may
    /// still hide the dragged tabs (DP1 waits).
    var hasDragInFlight: Bool { drag != nil || landing != nil || !commitsInFlight.isEmpty }

    // MARK: Begin

    func begin(_ start: TabDragStart, from pane: PaneController) {
        let item = Item.tab(start.tabID.rawValue)
        let payload = TabDragPayload.tab(id: start.tabID.rawValue, sourceStripID: start.stripID)
        begin(item: item, payload: payload, frame: start.screenFrame, grabOffset: start.grabOffset, point: start.screenPoint,
              image: start.snapshot?.cgImage, onGlass: start.snapshotOnGlass, previewTab: start.tabID.rawValue, draggedCount: 1, pane: pane)
    }

    func beginGroup(_ start: TabGroupDragStart, from pane: PaneController) {
        let item = Item.group(start.groupID, members: start.tabIDs.map(\.rawValue))
        let payload = TabDragPayload.tabGroup(id: start.groupID.rawValue, tabIDs: start.tabIDs.map(\.rawValue),
                                              sourceStripID: start.stripID, width: start.screenFrame.width)
        let preview = pane.stripModel.selectedID.flatMap { start.tabIDs.contains($0) ? $0.rawValue : nil } ?? start.tabIDs.first?.rawValue
        begin(item: item, payload: payload, frame: start.screenFrame, grabOffset: start.grabOffset, point: start.screenPoint,
              image: start.snapshot?.cgImage, onGlass: start.snapshotOnGlass, previewTab: preview, draggedCount: start.tabIDs.count, pane: pane)
    }

    /// `pane` is the source strip's pane (tab items); workspace items have
    /// no pane and name their source `window`. `onGlass`: `image` was drawn for glass in the
    /// source's scope (no card), which the ghost follows.
    func begin(item: Item, payload: TabDragPayload?, frame: CGRect, grabOffset: CGPoint, point: CGPoint, image: CGImage?,
               onGlass: Bool, previewTab: String?, draggedCount: Int, pane: PaneController?, window sourceWindow: WindowController? = nil) {
        if drag != nil { finish(commit: false) }
        finishLanding()

        let window = sourceWindow ?? services.windows.controllers.first { $0.content === pane?.workspace }
        var context = pane.map { Self.context(of: $0, item: item, draggedCount: draggedCount) } ?? .workspaces(count: draggedCount)
        if let window { context.sourceWindowWorkspaceCount = max(1, services.windows.registry.members(of: window.state.id).count) }
        let content = pane?.view.bounds ?? window?.content?.layoutView.bounds ?? .zero
        let aspect = content.width > 0 ? (content.height - Metrics.tabStripHeight) / content.width : nil
        let scale = window?.window?.backingScaleFactor ?? 2
        let rendersOnServer = LayoutTunables.motionRenderServer.value
        let ghost = TabDragGhostPanel(tabImage: image, tabSize: frame.size, grabOffset: grabOffset, aspect: aspect, scale: scale, onGlass: onGlass,
                                      sourceWindow: window?.window, rendersOnServer: rendersOnServer)
        var motion = TabDragGhostMotion(rect: frame, cardness: 0, reduceMotion: !Motion.tabs.animatesMovement,
                                        rectSpring: Motion.tabs.spring(.track), morphSpring: Motion.tabs.spring(.appear))
        // The card unfolds once its content preview arrives (`loadThumbnail`).
        motion.hasPreview = false
        let windowFrame = window?.window?.frame ?? .zero
        let source = Source(
            item: item, payload: payload, pane: pane, window: window, screenFrame: frame, grabOffset: grabOffset,
            tabOffset: CGPoint(x: frame.minX - windowFrame.minX, y: windowFrame.maxY - frame.maxY),
            windowSize: windowFrame.size, context: context
        )
        let lifecycle = TabDragLifecycle(restore: { [weak pane] in
            guard let pane else { return }
            Self.endPresentation(item, in: pane)
            pane.resyncStrip()
        }, release: { [weak pane] in
            // Every end, the landed ones too: a move into the tab's own strip
            // keeps the tab there, and the strip must show it again. The
            // store already holds the result; push it into the strip first,
            // so a tab that left is never shown back for a moment.
            guard let pane else { return }
            pane.syncStripFromStore()
            Self.endPresentation(item, in: pane)
        })
        let drag = Drag(source: source, lifecycle: lifecycle, ghost: ghost, motion: motion, point: point)
        // The drag's events, for the drag only: an intercept in the drag order (after the key router, before
        // AppKit dispatches), in every window, since the ghost crosses them. Chrome's Mac tab drag does the
        // same with a local monitor that lives for the move loop and ends it at the release or Escape
        // (components/remote_cocoa/app_shim/window_move_loop.mm, CocoaWindowMoveLoop::Run); here that
        // drag-lifetime monitor is routed through the one input tap.
        drag.input = services.inputTap.subscribe(class: Self.dragInput, phase: .intercept(order: .dragSession)) { [weak self] event in
            self?.handle(event) ?? .pass
        }
        // Its moves on the ghost window's coalescer (feature `pointerFrameDrags`), each delivery with its frame's time
        // for the resampled ghost (feature `resampledDrags`).
        drag.moves = moveFrames?.coalescer(for: ghost.panel).frameTimedConsumer(owner: Self.movesOwner) { [weak self, weak drag] input, frame in
            guard let self, let drag else { return }
            self.deliverMoves(input, at: frame, drag: drag)
        }
        drag.resampler = drag.moves == nil ? nil : makeResampler()
        resignObserver = services.appEvents.subscribe(NSApplication.didResignActiveNotification, owner: "TabDragSession.resign") { [weak self] in
            self?.finish(commit: false)
        }
        self.drag = drag
        focusDragBegan(item, from: pane)
        ghost.show()
        drag.link = ghost.makeFrameClient(owner: rendersOnServer ? "TabDrag.autoscroll" : "TabDrag.ghost") { [weak self, weak drag] tick in
            guard let self, let drag else { return false }
            return self.tick(drag, elapsed: tick.elapsed)
        }
        // On the render server the landing's last spring closes the ghost.
        ghost.onRest = { [weak self, weak drag] in
            guard let self, let drag, self.landing === drag else { return }
            self.finishLanding()
        }
        // The render server wakes it only for an auto-scroll or a dwell (`wake(_:over:)`).
        if !rendersOnServer { drag.link?.activate() }
        update(point)
        loadThumbnail(previewTab, into: drag)
    }

    func loadThumbnail(_ tab: String?, into drag: Drag) {
        guard let tab else { return }
        let cache = services.cache
        Task { [weak self, weak drag] in
            let image = await TabPreviewSource.shown(cache.previewImage(for: tab, maxPixelSize: TabPreviewFitting.cachedPixelSize, captureIfMissing: true),
                                                     key: tab, cache: cache)
            guard let drag, let image else { return }
            drag.ghost.setThumbnail(image)
            drag.motion.hasPreview = true
            self?.redraw(drag)
        }
    }

    static func context(of pane: PaneController, item: Item, draggedCount: Int) -> TabDragContext {
        TabDragContext(pane: pane, item: item, draggedCount: draggedCount)
    }

    /// The resolver's view of `drag` now: the source pane's tabs can change
    /// during a drag (another client, an agent), so the own place is read
    /// from the live strip model, not from the drag's start.
    func liveContext(_ drag: Drag) -> TabDragContext {
        guard let pane = drag.source.pane else { return drag.source.context }
        var context = Self.context(of: pane, item: drag.source.item, draggedCount: drag.source.context.draggedTabCount)
        context.sourceWindowWorkspaceCount = drag.source.context.sourceWindowWorkspaceCount
        return context
    }

    /// Ends the drag's presentation in its source strip: the hidden tab (or
    /// group) shows again wherever the model now has it.
    static func endPresentation(_ item: Item, in pane: PaneController) {
        switch item {
        case .tab(let id): pane.view.stripView.restoreDetachedTab(StripTabID(id))
        case .group(let id, _): pane.view.stripView.restoreDetachedGroup(id)
        case .workspaces: return
        }
    }

    // MARK: Events

    /// The tap classes a drag hears: its moves, the buttons (the release, and a press after a lost
    /// release) and keys (Escape). ``handle(_:)`` passes every other event of these classes on.
    static let dragInput: InputEventClasses = [.drag, .button, .key]

    /// One event of the drag; `.consume` keeps it from every later intercept and responder.
    func handle(_ event: NSEvent) -> InputEventTap.InterceptResult {
        switch event.type {
        case .leftMouseDragged:
            move(event)
            return .consume
        case .leftMouseUp:
            // The release hit-tests once, at its own point, and draws the ghost there: a move still waiting for its
            // frame is older, so it is dropped.
            drag?.moves?.cancel()
            update(Self.screenPoint(of: event))
            drag?.filesAway = event.modifierFlags.contains(.option)
            finish(commit: true)
            return .consume
        case .leftMouseDown:
            // A lost mouse-up (a nested tracking loop dequeued it, so sendEvent and the tap never saw
            // it): end safely, and the press goes on to what it hit.
            finish(commit: false)
            return .pass
        case .keyDown where event.keyCode == 53:
            finish(commit: false)
            return .consume
        default:
            return .pass
        }
    }

    /// The coalescer owner of a drag's moves.
    static let movesOwner = "TabDragSession.moves"

    /// One pointer move of the drag; every move feeds the release velocity. With ``Drag/moves`` the hit test and the
    /// ghost follow a frame interval's first move at once and the frame's latest move at its frame (Chromium's
    /// rAF-aligned input, `third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`); without it
    /// every move hit-tests.
    func move(_ event: NSEvent) {
        guard let drag else { return }
        let point = Self.screenPoint(of: event)
        guard let moves = drag.moves else { return update(point) }
        drag.samplePointer(point, at: CACurrentMediaTime())
        moves.post(Self.moveRecord(at: point, time: event.timestamp))
    }

    /// A move of the drag in screen coordinates and in no window: the ghost crosses windows, so its samples merge
    /// and resample in one space.
    static func moveRecord(at point: CGPoint, time: TimeInterval) -> InputEventRecord {
        let location = InputPoint(x: point.x, y: point.y)
        return InputEventRecord(type: .leftMouseDragged, timestamp: time, location: location, screenLocation: location)
    }

    /// One delivery of the drag's moves: a hit test at its latest real point, and the ghost drawn at the pointer
    /// resampled at `frame` while a resampler runs (Chromium's `MainThreadEventQueue::HandleEventResampling`,
    /// `ui/base/prediction/linear_resampling.cc`). A drag that ended before it gets none.
    func deliverMoves(_ input: PointerCoalescedInput, at frame: PointerFrameTime, drag: Drag) { // perf-hot: 2ms drag-frame (each leading or trailing delivery)
        guard self.drag === drag else { return }
        let real = CGPoint(x: input.latest.location.x, y: input.latest.location.y)
        let shown = drag.resampler?.points(for: input, at: frame).visualPoint
        retarget(real, shown: shown.map { CGPoint(x: $0.x, y: $0.y) }, drag: drag)
    }

    /// The event's own location, so events posted to this process (tests,
    /// automation) work without moving the real cursor.
    static func screenPoint(of event: NSEvent) -> CGPoint {
        if let window = event.window { return window.convertPoint(toScreen: event.locationInWindow) }
        return event.locationInWindow
    }

    // MARK: Hit testing

    /// The pointer is at `point` now: a sample for the release velocity, then a hit test there. `shown` is where the
    /// ghost is drawn (nil: at `point`).
    func update(_ point: CGPoint, shown: CGPoint? = nil) {
        guard let drag else { return }
        drag.samplePointer(point, at: CACurrentMediaTime())
        retarget(point, shown: shown, drag: drag)
    }

    /// One hit test of `drag` at the real `point` (drop target, autoscroll, window order), with the ghost drawn at
    /// `shown` (nil: at `point`).
    func retarget(_ point: CGPoint, shown: CGPoint?, drag: Drag) {
        drag.point = point
        drag.shownPoint = shown
        if case .workspaces = drag.source.item { return updateWorkspaces(point, drag: drag) }
        let context = liveContext(drag)
        let order = windowOrder(for: drag)
        let hit = hitTest(point, drag: drag, context: context, order: order)
        // The layout adapter's preview is ended by `outline`, so a move from
        // a pane zone to a strip slot animates instead of fading out and in.
        if let previous = drag.winner, previous.provider !== hit.winner?.provider, !(previous.provider is LayoutTabDropTarget) {
            previous.provider.dropExited()
        }
        drag.winner = hit.winner
        drag.resolution = TabDragResolver.resolve(hit.winner?.proposal, insideWindow: hit.window != nil, screenPoint: point,
                                                  context: context)
        drag.outcome = drag.resolution.outcome
        TabDragOutline.update(drag) { self.adapters(for: $0, drag: drag).layout }
        present(drag, order: order)
        wake(drag, over: hit.window)
    }

    struct Hit {
        var window: WindowController?
        var winner: Winner?
    }

    /// The first surface that answers at `point` wins, whatever its verdict:
    /// a stay or a refusal is previewed too, never skipped (tab-dnd). The
    /// sidebar and the layout answer for every point of their window.
    func hitTest(_ point: CGPoint, drag: Drag, context: TabDragContext, order: [TabDragWindowPick.Candidate]) -> Hit {
        drag.noTargetReason = nil
        guard let controller = window(at: point, in: order) else { return Hit() }
        guard let payload = drag.source.payload else { return Hit(window: controller) }
        // A tab never crosses between an incognito window and a normal one:
        // that window offers no drop target.
        if let source = drag.source.window?.state.id, services.windows.isIncognito(window: source)
            != services.windows.isIncognito(window: controller.state.id) {
            drag.noTargetReason = RefusalStrings.incognitoMismatch
            return Hit(window: controller)
        }
        let layout = adapters(for: controller, drag: drag).layout
        layout.removingPane = context.emptiesSourcePane ? LayoutPaneID(context.sourcePaneID) : nil
        for provider in providers(in: controller, near: point, drag: drag) {
            guard let proposal = provider.dropHitTest(screenPoint: point, payload: payload) else { continue }
            drag.touched[ObjectIdentifier(provider)] = provider
            return Hit(window: controller, winner: Winner(provider: provider, proposal: proposal, window: controller))
        }
        return Hit(window: controller)
    }

    /// Frontmost app window containing `point`; nil outside all of them.
    /// Chromium page windows, the overlay panel and the ghost are looked
    /// through (`TabDragWindowPick`).
    func window(at point: CGPoint) -> WindowController? {
        window(at: point, in: windowOrder(source: nil, ghost: nil))
    }

    /// Frontmost app window containing `point` in `order` (one walk of the windows serves a pointer event).
    func window(at point: CGPoint, in order: [TabDragWindowPick.Candidate]) -> WindowController? {
        guard let id = TabDragWindowPick.frontmost(at: point, in: order) else { return nil }
        return services.windows.controllers.first { $0.state.id == id }
    }

    /// The app's windows front to back, read once per pointer event: `drag`'s ghost and the source
    /// window's own children (its pages, its overlay) never hide the ghost's overlay.
    func windowOrder(for drag: Drag) -> [TabDragWindowPick.Candidate] {
        windowOrder(source: drag.source.window?.window, ghost: drag.ghost.panel)
    }

    func windowOrder(source: NSWindow?, ghost: NSWindow?) -> [TabDragWindowPick.Candidate] {
        let controllers = services.windows.controllers
        return NSApp.orderedWindows.map { window in
            TabDragWindowPick.Candidate(frame: window.frame,
                                        controllerID: controllers.first { $0.window === window }.map { $0.state.id },
                                        isVisible: window.isVisible && !window.isMiniaturized,
                                        occludes: window !== ghost && !Self.isChild(window, of: source))
        }
    }

    /// Whether `window` is a child window of `parent`, at any depth.
    static func isChild(_ window: NSWindow, of parent: NSWindow?) -> Bool {
        guard let parent else { return false }
        var current = window.parent
        while let next = current {
            if next === parent { return true }
            current = next.parent
        }
        return false
    }

    /// Drop targets of `controller` in priority order: sidebar, the strips
    /// near the point, then the layout.
    func providers(in controller: WindowController, near point: CGPoint, drag: Drag) -> [any TabDropTargetProviding] {
        let adapters = self.adapters(for: controller, drag: drag)
        var list: [any TabDropTargetProviding] = [adapters.sidebar]
        // A pinned dock's strip that takes no other tab takes no drop: the daemon would refuse it
        // (home-chief-pane.md H4). Home's dock takes tabs, so its strip takes drops.
        for pane in controller.onScreenContents.flatMap(\.panes.values) where !pane.isClosedPinnedDockPane {
            let strip = pane.view.stripView
            // visibility-walk-allow: hit test: a strip takes the drop only where AppKit draws it under the pointer (a pane's node says nothing of a hidden tab bar)
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
        let adapters = drag.adapters[key] ?? (SidebarTabDropTarget(bridge: controller.sidebar, window: controller), LayoutTabDropTarget(window: controller))
        drag.adapters[key] = adapters
        return adapters
    }

}
