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
    let context: LayoutViewContext
    var screenViews: [ScreenID: ScreenContentView] = [:]
    var screenFrames: [ScreenID: AnimatedFrame] = [:]
    let highlight = DropHighlightView()
    private let switcher = ScreenSwitcherView()
    let driver = DisplayLinkDriver()
    private var observationTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var lastSnapshot: Snapshot?
    private var reportedVisible: Set<PaneID> = []
    var scrollLock: ScrollLock = .idle
    var consumeMomentum = false
    var dragTab: TabID?

    /// Everything the view reads from the model, observed as one value.
    private struct Snapshot: Equatable, Sendable {
        var screens: [LayoutScreen]
        var activeScreen: ScreenID?
        var focused: PaneID?
        var showsSwitcher: Bool
        var dimsInactive: Bool
        var style: LayoutStyle
        var gestureActive: Bool
        var centerRequest: ColumnCenterRequest?
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
            switcher.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.space4),
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

    // MARK: Observation

    private func snapshot() -> Snapshot {
        Snapshot(
            screens: model.screens,
            activeScreen: model.activeScreenID,
            focused: model.focusedPane,
            showsSwitcher: model.showsScreenSwitcher,
            dimsInactive: model.dimsInactivePanes,
            style: model.style,
            gestureActive: model.isGestureActive,
            centerRequest: model.centerRequest
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
                    gestureActive: model.isGestureActive,
                    centerRequest: model.centerRequest
                )
            }) {
                guard let self else { return }
                if snapshot != self.lastSnapshot { self.sync(snapshot) }
            }
        }
    }

    var canAnimate: Bool { window != nil && driver.isAttached && !context.reduceMotion }

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
            if let request = snapshot.centerRequest, request != previous?.centerRequest, screen.layout.contains(request.pane),
               view.reveal(request.pane, mode: .center, animated: animated) {
                needsFrames = true
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

    func updateVisibility() {
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

}
