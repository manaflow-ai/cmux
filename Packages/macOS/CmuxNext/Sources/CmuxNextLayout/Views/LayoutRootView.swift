public import AppKit
import CmuxNextDesign
import Observation

/// The workspace content area: renders every screen of a `LayoutModel`,
/// hosts App-provided pane views, and turns pointer and trackpad input into
/// `LayoutIntent`s.
///
/// Horizontal trackpad scrolling over a columns screen belongs to the layout
/// even when a hosted view (a terminal) is under the pointer: the first
/// dominant axis of each gesture decides, and vertical gestures pass through.
public final class LayoutRootView: NSView {
    public let model: LayoutModel
    private let context: LayoutViewContext
    private var screenViews: [ScreenID: ScreenContentView] = [:]
    private var screenFrames: [ScreenID: AnimatedFrame] = [:]
    private let highlight = DropHighlightView()
    private let switcher = ScreenSwitcherView()
    private let driver = DisplayLinkDriver()
    private var observationTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var lastSnapshot: Snapshot?
    private var reportedVisible: Set<PaneID> = []
    private var scrollLock: ScrollLock = .idle
    private var consumeMomentum = false
    private var dragTab: TabID?

    private enum ScrollLock {
        case idle
        case undecided(ScreenContentView)
        case horizontal(ScreenContentView)
        case passthrough
    }

    /// Everything the view reads from the model, observed as one value.
    private struct Snapshot: Equatable, Sendable {
        var screens: [LayoutScreen]
        var activeScreen: ScreenID?
        var focused: PaneID?
        var showsSwitcher: Bool
        var dimsInactive: Bool
        var style: LayoutStyle
        var gestureActive: Bool
    }

    /// `contentProvider` is held weakly; the App keeps it alive.
    public init(model: LayoutModel, contentProvider: any LayoutPaneContentProvider) {
        self.model = model
        self.context = LayoutViewContext(model: model, provider: contentProvider)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        context.requestFrames = { [weak self] in self?.driver.start() }
        driver.onFrame = { [weak self] dt in self?.frame(dt) ?? false }
        addSubview(highlight)
        addSubview(switcher)
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            switcher.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        switcher.onSelect = { [weak self] id in self?.model.selectScreen(id) }
        registerForDraggedTypes([LayoutTabDrag.pasteboardType])
        sync(snapshot())
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        observationTask?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        driver.detach()
    }

    override public var isFlipped: Bool { true }

    // MARK: Public API

    /// Moves focus to the neighbor in `direction`, scrolling its column into view.
    @discardableResult
    public func moveFocus(_ direction: LayoutDirection) -> PaneID? {
        guard let active = model.activeScreenID, let view = screenViews[active] else { return nil }
        return model.moveFocus(direction, frames: view.geometry.panes)
    }

    /// The hosted content view of `pane`, if it has been created.
    public func contentView(for pane: PaneID) -> NSView? {
        context.hosts[pane]?.content
    }

    /// Displayed frame of `pane` in this view's coordinates (active screen only).
    public func frame(of pane: PaneID) -> CGRect? {
        guard let active = model.activeScreenID, let view = screenViews[active], let rect = view.displayedFrame(of: pane) else { return nil }
        return rect.offsetBy(dx: view.frame.minX, dy: view.frame.minY)
    }

    /// Updates the drop highlight for an in-process tab drag (for tab strips
    /// that track the mouse themselves instead of using NSDraggingSession).
    @discardableResult
    public func updateTabDrag(_ tab: TabID, locationInWindow: NSPoint) -> DropTarget? {
        dragTab = tab
        guard let active = model.activeScreenID, let view = screenViews[active] else {
            hideHighlight()
            return nil
        }
        let local = view.convert(locationInWindow, from: nil)
        guard let hit = view.dropTarget(at: local) else {
            hideHighlight()
            return nil
        }
        let rect = convert(hit.highlight, from: view)
        if highlight.show(rect, text: LayoutStrings.label(for: hit.target), animated: canAnimate) { driver.start() }
        return hit.target
    }

    /// Ends a tab drag. Emits `.dropTab` when over a target and returns it.
    @discardableResult
    public func endTabDrag(_ tab: TabID, locationInWindow: NSPoint) -> DropTarget? {
        let target = updateTabDrag(tab, locationInWindow: locationInWindow)
        hideHighlight()
        dragTab = nil
        if let target { model.dropTab(tab, on: target) }
        return target
    }

    public func cancelTabDrag() {
        dragTab = nil
        hideHighlight()
    }

    private func hideHighlight() {
        if highlight.hide(animated: canAnimate) { driver.start() }
    }

    // MARK: Observation

    private func snapshot() -> Snapshot {
        Snapshot(
            screens: model.screens,
            activeScreen: model.activeScreenID,
            focused: model.focusedPane,
            showsSwitcher: model.showsScreenSwitcher,
            dimsInactive: model.dimsInactivePanes,
            style: model.style,
            gestureActive: model.isGestureActive
        )
    }

    private func observe() {
        let model = model
        observationTask = Task { [weak self] in
            for await snapshot in Observations({
                Snapshot(
                    screens: model.screens,
                    activeScreen: model.activeScreenID,
                    focused: model.focusedPane,
                    showsSwitcher: model.showsScreenSwitcher,
                    dimsInactive: model.dimsInactivePanes,
                    style: model.style,
                    gestureActive: model.isGestureActive
                )
            }) {
                guard let self else { return }
                if snapshot != self.lastSnapshot { self.sync(snapshot) }
            }
        }
    }

    private var canAnimate: Bool { window != nil && driver.isAttached && !context.reduceMotion }

    private func sync(_ snapshot: Snapshot) {
        let previous = lastSnapshot
        lastSnapshot = snapshot
        let animated = previous != nil && canAnimate && !snapshot.gestureActive
        var needsFrames = false

        context.livePanes = Set(snapshot.screens.flatMap(\.layout.panes))

        // Screens.
        let ids = Set(snapshot.screens.map(\.id))
        for (id, view) in screenViews where !ids.contains(id) {
            view.tearDown()
            view.removeFromSuperview()
            screenViews[id] = nil
            screenFrames[id] = nil
        }
        for screen in snapshot.screens {
            let isActive = screen.id == snapshot.activeScreen
            let view: ScreenContentView
            if let existing = screenViews[screen.id] {
                view = existing
            } else {
                view = ScreenContentView(screenID: screen.id, layout: screen.layout, context: context)
                view.frame = bounds
                view.isHidden = !isActive
                addSubview(view, positioned: .below, relativeTo: highlight)
                screenViews[screen.id] = view
                screenFrames[screen.id] = AnimatedFrame(bounds, alpha: isActive ? 1 : 0)
            }
            let structureChanged = previous?.screens.first(where: { $0.id == screen.id }).map { !sameStructure($0.layout, screen.layout) } ?? true
            if view.update(layout: screen.layout, animated: animated) { needsFrames = true }
            view.updateChrome(focused: snapshot.focused, dimsInactive: snapshot.dimsInactive)
            if let focused = snapshot.focused, screen.layout.contains(focused),
               structureChanged || previous?.focused != focused
            {
                if view.reveal(focused, mode: model.columnRevealMode, animated: animated) { needsFrames = true }
            }
        }

        // Screen switch.
        if previous?.activeScreen != snapshot.activeScreen {
            if switchScreens(from: previous?.activeScreen, to: snapshot.activeScreen, order: snapshot.screens.map(\.id), animated: animated) {
                needsFrames = true
            }
        }

        switcher.isHidden = !snapshot.showsSwitcher
        if snapshot.showsSwitcher {
            switcher.update(screens: snapshot.screens, active: snapshot.activeScreen)
        }
        updateVisibility()
        if needsFrames || snapshot.gestureActive { driver.start() }
    }

    /// Same panes, splits, and columns in the same places; ratios and widths may differ.
    private func sameStructure(_ a: ScreenLayout, _ b: ScreenLayout) -> Bool {
        switch (a, b) {
        case let (.splits(x), .splits(y)):
            return x.panes == y.panes && x.splits == y.splits
        case let (.columns(x), .columns(y)):
            return x.map(\.id) == y.map(\.id) && x.map(\.root.panes) == y.map(\.root.panes)
        default:
            return false
        }
    }

    private func switchScreens(from old: ScreenID?, to new: ScreenID?, order: [ScreenID], animated: Bool) -> Bool {
        let oldIndex = old.flatMap { order.firstIndex(of: $0) } ?? -1
        let newIndex = new.flatMap { order.firstIndex(of: $0) } ?? 0
        let direction: CGFloat = newIndex >= oldIndex ? 1 : -1
        let shift = bounds.width * 0.18
        for (id, view) in screenViews {
            guard var frame = screenFrames[id] else { continue }
            if id == new {
                if view.isHidden || frame.alpha.value < 0.01 {
                    frame = AnimatedFrame(bounds.offsetBy(dx: direction * shift, dy: 0), alpha: 0)
                }
                view.isHidden = false
                frame.setTarget(bounds, alpha: 1)
            } else if id == old {
                frame.setTarget(bounds.offsetBy(dx: -direction * shift, dy: 0), alpha: 0)
            } else {
                frame.setTarget(bounds, alpha: 0)
                frame.snap()
            }
            if !animated { frame.snap() }
            screenFrames[id] = frame
        }
        applyScreenFrames()
        return animated
    }

    private func applyScreenFrames() {
        for (id, frame) in screenFrames {
            guard let view = screenViews[id] else { continue }
            view.setFrameOrigin(frame.rect.origin)
            if view.frame.size != bounds.size { view.setFrameSize(bounds.size) }
            view.alphaValue = frame.alpha.value
            if id != model.activeScreenID && frame.alpha.value <= 0.001 && frame.alpha.target == 0 {
                view.isHidden = true
            }
        }
    }

    // MARK: Frames

    private func frame(_ dt: Double) -> Bool {
        model.flushPendingGestureIntents()
        var moving = false
        for view in screenViews.values where !view.isHidden {
            if view.step(dt) { moving = true }
        }
        for id in Array(screenFrames.keys) {
            if screenFrames[id]!.advance(dt, parameters: .screen) { moving = true }
        }
        applyScreenFrames()
        if highlight.step(dt) { moving = true }
        updateVisibility()
        return moving || model.isGestureActive || model.hasPendingGestureIntents
    }

    private func updateVisibility() {
        var visible: Set<PaneID> = []
        if window != nil, let active = model.activeScreenID, let view = screenViews[active] {
            visible = view.visiblePanes()
        }
        guard visible != reportedVisible else { return }
        let appeared = visible.subtracting(reportedVisible)
        let disappeared = reportedVisible.subtracting(visible)
        reportedVisible = visible
        model.reportVisiblePanes(visible)
        for pane in appeared { context.provider?.paneVisibilityDidChange(pane, isVisible: true) }
        for pane in disappeared { context.provider?.paneVisibilityDidChange(pane, isVisible: false) }
    }

    // MARK: Layout and window

    override public func layout() {
        super.layout()
        for (id, view) in screenViews {
            if view.frame.size != bounds.size { view.setFrameSize(bounds.size) }
            if var frame = screenFrames[id] {
                let target = id == model.activeScreenID ? bounds : bounds.offsetBy(dx: 0, dy: 0)
                frame.setTarget(target)
                frame.x.snap(); frame.y.snap(); frame.width.snap(); frame.height.snap()
                screenFrames[id] = frame
            }
        }
        applyScreenFrames()
        updateVisibility()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        driver.detach()
        guard window != nil else {
            updateVisibility()
            return
        }
        driver.attach(to: self)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleMonitored(event) ?? event
        }
        updateVisibility()
    }

    // MARK: Event routing

    private func handleMonitored(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window != nil else { return event }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), let active = model.activeScreenID, let view = screenViews[active] else { return event }
            if let pane = view.pane(at: view.convert(event.locationInWindow, from: nil)) {
                model.focus(pane)
            }
            return event
        case .scrollWheel:
            return handleScroll(event)
        default:
            return event
        }
    }

    private func activeColumnsView(at locationInWindow: NSPoint) -> ScreenContentView? {
        guard bounds.contains(convert(locationInWindow, from: nil)),
              let active = model.activeScreenID, let view = screenViews[active], view.acceptsHorizontalScroll else { return nil }
        return view
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        // Momentum after a horizontal gesture we consumed: our spring owns the coast.
        if !event.momentumPhase.isEmpty {
            guard consumeMomentum else { return event }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { consumeMomentum = false }
            return nil
        }

        let phase = event.phase
        if phase.isEmpty {
            // Discrete mouse wheel. Shift+wheel arrives as deltaX.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), let view = activeColumnsView(at: event.locationInWindow) else { return event }
            view.discreteScroll(direction: event.scrollingDeltaX < 0 ? 1 : -1)
            driver.start()
            return nil
        }

        if phase.contains(.mayBegin) || phase.contains(.began) {
            consumeMomentum = false
            if let view = activeColumnsView(at: event.locationInWindow) {
                scrollLock = .undecided(view)
            } else {
                scrollLock = .passthrough
            }
        }

        switch scrollLock {
        case .idle, .passthrough:
            if phase.contains(.ended) || phase.contains(.cancelled) { scrollLock = .idle }
            return event
        case let .undecided(view):
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if phase.contains(.ended) || phase.contains(.cancelled) {
                scrollLock = .idle
                return event
            }
            guard dx + dy > 0 else { return event }
            if dx > dy {
                scrollLock = .horizontal(view)
                view.beginUserScroll()
                view.userScroll(deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
                return nil
            }
            scrollLock = .passthrough
            return event
        case let .horizontal(view):
            if phase.contains(.ended) || phase.contains(.cancelled) {
                view.endUserScroll(timestamp: event.timestamp)
                scrollLock = .idle
                consumeMomentum = true
                driver.start()
            } else {
                view.userScroll(deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
                updateVisibility()
            }
            return nil
        }
    }

    // MARK: NSDraggingDestination

    private func tabID(from info: any NSDraggingInfo) -> TabID? {
        info.draggingPasteboard.string(forType: LayoutTabDrag.pasteboardType).map(TabID.init(rawValue:))
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let tab = tabID(from: sender), updateTabDrag(tab, locationInWindow: sender.draggingLocation) != nil else {
            hideHighlight()
            return []
        }
        return .move
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        cancelTabDrag()
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let tab = tabID(from: sender) else { return false }
        return endTabDrag(tab, locationInWindow: sender.draggingLocation) != nil
    }

    override public func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        cancelTabDrag()
    }
}
