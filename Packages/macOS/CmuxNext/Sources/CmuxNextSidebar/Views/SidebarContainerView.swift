public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups

/// The sidebar: clear over the window's one backdrop (the solid surface
/// token, or the root material and its tint), with no fill, panel, border
/// or seam (plans/cmux-next/windows.md). It owns its width.
///
/// Pin the edge of `side` (leading by default), top, and bottom; the view
/// animates its own width constraint between the user's width
/// (`SidebarModel.presentation == .shown`) and 0 (`.hidden`), and follows
/// live resizing through the handle on the edge facing the content.
/// Neighbors should attach to that edge so they follow and reach the window
/// edge when the sidebar hides.
///
/// While the width animates, the sidebar content keeps its full width and
/// slides out past the window edge (a clip view hides the overflow), so
/// rows never reflow mid-animation. Once hidden, the content is
/// `isHidden`: it cannot hold focus, take drops or appear to VoiceOver.
/// With `motion.renderServer` on, the width is set once and the slide runs
/// on the render server (`SidebarContainerView+RenderSlide`).
public final class SidebarContainerView: NSView {
    public let sidebarView: SidebarView
    public let model: SidebarModel
    /// The width constraint this view drives. Do not add another.
    /// Built in init (lazy because it anchors self; no IUO).
    public private(set) lazy var widthConstraint: NSLayoutConstraint = widthAnchor.constraint(equalToConstant: model.displayWidth)

    /// Clips the sliding panel to the container's (animating) width. Internal, not private: a
    /// render-server slide springs it from its own file (`SidebarContainerView+RenderSlide`).
    let clip = NSView()
    /// Holds the sidebar at `model.width`, pinned to the clip's edge that
    /// faces the content (`side`). Internal for the same reason as `clip`.
    let panel = NSView()
    /// Internal, not private: the resize drag sets it from its own file
    /// (`SidebarContainerView+Resize`).
    lazy var panelWidth: NSLayoutConstraint = panel.widthAnchor.constraint(equalToConstant: model.width)
    let handle: SidebarResizeHandle
    /// The thin rail (`sidebar.style` = rail) and its open state (`SidebarContainerView+Rail`).
    public let railView = SidebarRailView()
    let railCards = SidebarRailHoverCards()
    /// The presentation, width and band tokens the container follows (`observe`): a service observation, since its
    /// apply writes the model (`followDefaultWidth`, `syncRail`) and must run while the window is hidden (rule 3).
    private var observation: ServiceObservation<PresentationInputs>?
    /// The sidebar's one watch of its Debug Settings looks (``SidebarLookWatch``), made in `init`.
    private var lookWatch: SidebarLookWatch?
    /// Width the constraint is at or animating to. The animator reports
    /// intermediate constants, so compare against this instead. Internal for
    /// the same reason as `panelWidth`.
    var targetWidth: CGFloat
    /// Bumped per width animation; a stale completion does nothing. Internal, not private, with the two
    /// gates below: a render-server slide starts its legs from its own file (`SidebarContainerView+RenderSlide`).
    var animationGeneration = 0
    /// Completion gates for the optional opacity leg. Width and opacity use
    /// separate tokens, so a reduced-motion fade can finish after the width
    /// snaps without exposing a panel that is not ready to be hidden.
    var widthCompletedGeneration: Int?
    var fadeCompletedGeneration: Int?
    /// The collapse prototype used by the current transition. Keeping it
    /// alongside the width target lets a Debug Settings change retarget a
    /// transition already in flight without changing the default geometry.
    private var targetCollapseMotion: SidebarCollapseMotionVariant
    /// Whether the width is animating now: every frame of it moves the content
    /// edge beside the sidebar, so content whose resize is costly (a terminal's
    /// PTY grid) holds it until the landing
    /// (`ContentAreaMotionHosting`, `onWidthMotionChange`).
    /// Set only inside this package: `apply()` starts the motion and the
    /// animation's completion, `snap()`, a drag or the watchdog
    /// (`SidebarContainerView+WidthMotion`) end it. `internal(set)` and not
    /// `private(set)` because the watchdog lives in that file.
    public internal(set) var isWidthAnimating = false {
        didSet {
            guard isWidthAnimating != oldValue else { return }
            if !isWidthAnimating { widthMotionWatchdog.cancel(); applySurfaceFill() }
            onWidthMotionChange?(isWidthAnimating)
        }
    }
    /// Called when the width starts and stops animating. The window tells its
    /// content when the motion lands (`NSView.notifyPaneMotionSettled`).
    public var onWidthMotionChange: ((Bool) -> Void)?
    /// Called each time a width animation starts or turns around mid-flight, with the
    /// sidebar's on-screen width and the width it animates to, before the first frame. The
    /// window sizes its content once for the whole slide from these (`MainPaneCardView.contentHold`).
    /// A render-server slide calls it before its one layout, with ``widthMotionBackend`` already set.
    public var onWidthMotionStart: ((_ from: CGFloat, _ to: CGFloat) -> Void)?
    /// Where the width motion runs, set at each slide's start. A main-thread slide moves the content
    /// edge every frame; a render-server slide sizes everything once in its turn, so the content beside
    /// it is at its final size through the slide (`WindowRootView.isContentAreaInMotion`).
    public internal(set) var widthMotionBackend: MotionBackend = .cpuStep
    /// Whether the slide runs on the render server (`motion.renderServer`, off by default; the window
    /// passes the app's switch), read in each slide's turn.
    public var rendersMotionOnServer: () -> Bool = { false }
    /// Whether the window can show this slide on the render server now, read in each slide's turn: false
    /// while content beside the sidebar draws in its own child window, which follows the views' model
    /// frames and not a layer spring (the window's `ChildWindowContent` rule, as the layout's zoom).
    public var slideCanRunOnRenderServer: () -> Bool = { true }
    /// The window's part of a render-server slide: called in its turn before its one layout, to note
    /// where the views beside the sidebar show; the closure it returns, called after the layout, returns
    /// the springs that carry them from there to rest (`SidebarContainerView+RenderSlide`).
    public var slideFollowers: (() -> () -> [RenderSpring.Move])?
    /// The slide's backends (`SidebarSlideRenderMotion`), selected by ``rendersMotionOnServer``.
    lazy var motionBackends = MotionBackends<SidebarContainerView>(
        SidebarContainerView.renderServerMotions, renderServer: { [weak self] in self?.rendersMotionOnServer() ?? false })
    /// The slide the running `apply()` starts, for its render-server variant; nil outside `apply()`.
    var pendingSlide: SidebarSlide?
    /// The layers and key paths the render-server slides since the last landing spring, the window's
    /// followers too, so a snap or a drag stops all of them (`stopRenderSlide`).
    var renderSlideSprings: [(layer: CALayer, keyPath: String)] = []
    /// Paces hover refreshes while the width animates. Hover follows views
    /// sliding under a still pointer (cx-3wu5), which needs no 120 Hz: a
    /// refresh walks every hover target of the window, so one deadline is
    /// pending at a time and the landing runs the last refresh.
    let hoverRefresh: MainDeadline
    static let hoverRefreshDelay: Duration = .milliseconds(33)
    /// Ends the motion if the animation's completion never arrives. AppKit
    /// leaves an `animator()` change where it stands when the display sleeps
    /// mid-animation and drops its completion (`MotionInFlight`), and
    /// `animateTimed` has no `settleAtSleep` route out of that. A lost
    /// completion used to leave a collapsed panel visible at width 0; now it
    /// would also leave `isWidthAnimating` true, and with it every terminal in
    /// the window holding its grid report for good. The motion ends on its own
    /// shortly after it was due instead.
    let widthMotionWatchdog: MainDeadline
    /// How long past an animation's own duration the watchdog waits.
    static let widthMotionSlack: Duration = .milliseconds(500)

    /// The window edge this sidebar sits on (`sidebar.side`, R109): the
    /// resize handle and the slide-out follow it.
    public var side: SidebarSide = .left {
        didSet { if side != oldValue { applySide() } }
    }
    /// The panel pins of each side (`applySide`).
    var sidePins: [SidebarSide: [NSLayoutConstraint]] = [:]
    /// The handle's pins (`mountHandle`), rebuilt when it moves or the band changes.
    var handleConstraints: [NSLayoutConstraint] = []
    /// The band the handle is pinned to now.
    var mountedBand: SidebarResizeBand?

    /// Dragging the resize edge narrower than this hides the sidebar
    /// (there is no intermediate width below `Metrics.sidebarMinWidth`).
    public static var hideThreshold: CGFloat { Metrics.sidebarMinWidth / 2 }


    /// - Parameters:
    ///   - model: What the sidebar shows.
    ///   - deadlines: The app's one deadline placer. Its ``MainDeadlineScheduler/work`` is the app's main-thread
    ///     scheduler: the presentation observation flushes and the rows' and headers' Debug Settings looks follow
    ///     through it, once per frame, and the list and the rail draw through it while they show. The hover pacing,
    ///     the width motion's watchdog, the list's spring-load hover and the Priority view's minute tick are
    ///     deadlines on it.
    ///   - appEvents: The app's one fan-out of app-wide notices (`AppServices.appEvents`): the list ends a pointer
    ///     gesture when the app resigns active.
    ///   - newRows: Told which rows the list draws, so a new workspace's `create.workspace` interval ends there.
    ///   - responsiveScrolling: The list scrolls on AppKit's scrolling thread (feature `responsiveScrolling`).
    public init(model: SidebarModel, deadlines: MainDeadlineScheduler, appEvents: AppEvents, newRows: SidebarNewRowTimer? = nil,
                responsiveScrolling: Bool = false) {
        let mainWork = deadlines.work
        self.model = model
        hoverRefresh = MainDeadline(owner: "Sidebar.hoverRefresh", workClass: .visible, scheduler: deadlines)
        widthMotionWatchdog = MainDeadline(owner: "Sidebar.widthMotionWatchdog", workClass: .visible, scheduler: deadlines)
        sidebarView = SidebarView(model: model, mainWork: mainWork, newRows: newRows, responsiveScrolling: responsiveScrolling)
        handle = SidebarResizeHandle()
        targetWidth = model.displayWidth
        targetCollapseMotion = SidebarTunables.collapseMotion.value
        widthCompletedGeneration = nil
        fadeCompletedGeneration = nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        for view in [clip, panel, sidebarView, handle] { view.translatesAutoresizingMaskIntoConstraints = false }
        panel.addSubview(sidebarView)
        clip.addSubview(panel)
        addSubview(clip)
        NSLayoutConstraint.activate([
            widthConstraint,
            panelWidth,
            sidebarView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            sidebarView.topAnchor.constraint(equalTo: panel.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.topAnchor.constraint(equalTo: topAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.topAnchor.constraint(equalTo: clip.topAnchor),
            panel.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        sidePins = Self.pins(panel: panel, clip: clip)
        NSLayoutConstraint.activate(sidePins[side] ?? [])
        mountHandle()
        panel.isHidden = isPanelCollapsed
        syncHandleVisibility()
        handle.restingLineWidth = Metrics.sidebarBorderWidth
        handle.onDrag = { [weak self] phase in self?.handleDrag(phase) }
        mountRail(on: mainWork)
        sidebarView.list.appEvents = appEvents
        sidebarView.list.deadlines = deadlines
        sidebarView.priorityPanelView.follow(deadlines, visibility: sidebarView.list.visibility)
        observe(on: mainWork)
        lookWatch = SidebarLookWatch(root: self, on: mainWork)
    }

    /// A container with a deadline placer and an app-notice fan-out of its own on `mainWork`'s wake queue and the
    /// default center (tests; the App passes its one of each).
    public convenience init(model: SidebarModel, mainWork: MainWorkScheduler, newRows: SidebarNewRowTimer? = nil) {
        self.init(model: model, deadlines: MainDeadlineScheduler(work: mainWork), appEvents: AppEvents(center: .default), newRows: newRows)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
        }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurfaceFill()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySurfaceFill()
    }

    /// The handle follows into the new superview (`mountHandle`).
    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil, handle.superview !== self {
            NSLayoutConstraint.deactivate(handleConstraints)
            handle.removeFromSuperview()
        }
    }

    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        mountHandle()
    }

    // The handle sits in the superview, not under this view: it hides and fades with it here.
    override public func viewDidHide() {
        super.viewDidHide()
        syncHandleVisibility()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        syncHandleVisibility()
    }

    override public var alphaValue: CGFloat {
        didSet { handle.alphaValue = alphaValue }
    }

    /// The handle shows while the sidebar is shown and this view is not hidden.
    private func syncHandleVisibility() {
        // visibility-walk-allow: the handle lives in the superview, so it copies this view's own AppKit hidden state (no node holds a view's isHidden)
        handle.isHidden = isPanelCollapsed || isHiddenOrHasHiddenAncestor
    }

    /// Clear over the window's backdrop, or the user's sidebar background
    /// (`appearance.surfaces.sidebar`, `Palette.surfaceOverride`).
    func applySurfaceFill() {
        clip.layer?.backgroundColor = performWithTheme { (Palette.surfaceOverride(.sidebar) ?? railOverlayFill)?.cgColor }
    }

    // MARK: Public API

    /// Restores saved state without animating (window creation, relaunch).
    public func restore(width: CGFloat?, presentation: SidebarPresentation) {
        if let width { model.width = width }
        model.presentation = presentation
        animationGeneration += 1
        snap()
    }

    /// Starts inline rename of a workspace, showing the sidebar first when
    /// it is hidden (the rename field lives in the list).
    public func beginRename(workspace id: WorkspaceID) {
        revealForEditing()
        sidebarView.beginRename(workspace: id)
    }

    /// Starts inline rename of a group, showing the sidebar first when it
    /// is hidden.
    public func beginRename(group id: GroupID) {
        revealForEditing()
        sidebarView.beginRename(group: id)
    }

    /// Turns the sidebar's edit mode on or off (`SidebarView+EditItems`), showing a hidden sidebar first.
    public func toggleEditingItems() {
        let on = !sidebarView.isEditingItems
        if on { revealForEditing() }
        sidebarView.setEditingItems(on)
    }

    /// Shows a hidden sidebar and lays its rows out now, so a rename field
    /// can attach to a row in the same turn. The width still animates.
    private func revealForEditing() {
        if model.style == .rail, !model.isHidden { revealRail() }
        guard model.isHidden else { return }
        model.presentation = .shown
        apply()
        // sync-layout: a rename field attaches to a laid-out row in this turn.
        panel.layoutSubtreeIfNeeded()
    }

    // MARK: Resize

    /// The width the live drag started from. The drag itself is in
    /// `SidebarContainerView+Resize`; a stored property cannot live there.
    var liveStartWidth: CGFloat = 0

    // MARK: Observation

    /// What `observe` follows. The default width token is tracked so a settings change resizes live. The collapse
    /// prototype is tracked here too, so Debug Settings retargets an in-flight transition.
    private struct PresentationInputs: Equatable {
        let presentation: SidebarPresentation
        let style: SidebarLayoutStyle
        let isRailOpen: Bool
        let width: CGFloat
        let defaultWidth: CGFloat
        let border: CGFloat
        let collapseMotion: SidebarCollapseMotionVariant
        let band: [CGFloat]
    }

    /// Follows the model's presentation and the width tokens: applied now, then once per change in the change's class
    /// (a person's toggle in userBlocking, before the commit of its input; Chrome's posted UI-thread task with a
    /// TaskPriority, base/task/task_traits.h).
    private func observe(on mainWork: MainWorkScheduler) {
        let model = model
        observation = ServiceObservation(.visible, owner: "Sidebar.presentation", on: mainWork) {
            PresentationInputs(presentation: model.presentation, style: model.style, isRailOpen: model.isRailOpen,
                               width: model.width, defaultWidth: Metrics.sidebarWidth, border: Metrics.sidebarBorderWidth,
                               collapseMotion: SidebarTunables.collapseMotion.value,
                               band: [Metrics.dividerHitWidth, Metrics.mainPaneGutter])
        } apply: { [weak self] inputs in
            guard let self else { return }
            handle.restingLineWidth = inputs.border
            if resizeBand != mountedBand { mountHandle() }
            followDefaultWidth(inputs.defaultWidth)
            syncRail()
            apply()
        }
    }

    private var lastDefaultWidth: CGFloat?

    /// When the user changes the sidebar width setting, adopt it.
    private func followDefaultWidth(_ value: CGFloat) {
        defer { lastDefaultWidth = value }
        guard let last = lastDefaultWidth, last != value else { return }
        model.width = value
    }

    /// The width animation lays the sidebar out each frame and a hide ends
    /// it: views slide or hide under a still pointer, and hover follows
    /// (cx-3wu5). A refresh walks every hover target of the window, so while
    /// the width animates one runs every `hoverRefreshDelay` instead of every
    /// frame, and the landing runs the last one, so the settled geometry
    /// always decides which view is hovered.
    override public func layout() {
        super.layout()
        guard isWidthAnimating else {
            refreshHover()
            return
        }
        hoverRefresh.scheduleIfIdle(after: Self.hoverRefreshDelay) { [weak self] in self?.refreshHover() }
    }

    /// Sets every constraint and visibility for the model without animating. The caller bumps
    /// `animationGeneration`, so a render-server slide stopped here lands as nothing.
    private func snap() {
        targetWidth = model.displayWidth
        targetCollapseMotion = SidebarTunables.collapseMotion.value
        isWidthAnimating = false
        stopRenderSlide()
        widthConstraint.constant = targetWidth
        panelWidth.constant = model.width
        panel.isHidden = isPanelCollapsed
        panel.alphaValue = 1
        syncHandleVisibility()
        syncRail()
    }

    /// Animates to the model's presentation with the appear / disappear tokens (instant with
    /// Reduce Motion). Idempotent: a repeat call for the same target does
    /// nothing, so the observation and a synchronous caller can both run it.
    func apply() {
        let hidden = isPanelCollapsed
        let target = model.displayWidth
        let collapseMotion = SidebarTunables.collapseMotion.value
        panelWidth.constant = model.width
        syncHandleVisibility()
        if handle.isDragging, !hidden {
            targetWidth = target
            targetCollapseMotion = collapseMotion
            // A drag is the person's own frame-by-frame resize, not an animation. A render-server
            // slide still running stops where it rests, so the edge stays under the pointer.
            if stopRenderSlide() != nil { animationGeneration += 1 }
            isWidthAnimating = false
            widthConstraint.constant = target
            return
        }
        guard targetWidth != target || targetCollapseMotion != collapseMotion else { return }
        targetWidth = target
        targetCollapseMotion = collapseMotion
        if !hidden { panel.isHidden = false }
        animationGeneration += 1
        let generation = animationGeneration
        pendingSlide = SidebarSlide(to: target, hidden: hidden, fadesPanel: collapseMotion.fadesPanel, generation: generation)
        defer { pendingSlide = nil }
        if motionBackends.begin(on: self, policy: Motion.sidebar.policy).contains(.sidebarSlide) { return }
        // A render-server slide still running (a page window showed or the switch turned off mid-slide)
        // stops; the main thread's slide starts from the width it showed.
        if let shown = stopRenderSlide() { widthConstraint.constant = shown }
        widthMotionBackend = .cpuStep
        // The slide-and-fade prototype starts an expansion transparent and
        // lets the same timed transition reveal it. Slide keeps the current
        // opaque panel behavior, including when a user switches variants
        // while the sidebar is already visible.
        if !hidden { panel.alphaValue = collapseMotion.fadesPanel ? 0 : 1 }
        // With no animation at all (Reduce Motion, the gate off) the width lands
        // in this turn and the completion clears this again at once.
        isWidthAnimating = true
        onWidthMotionStart?(frame.width, target)
        armWidthMotionWatchdog(hidden ? .disappear : .appear)
        widthCompletedGeneration = nil
        fadeCompletedGeneration = collapseMotion.fadesPanel ? nil : generation
        // Animate only the constraint: descendants re-lay out each frame at
        // their real size. Forcing layout inside the animation block would
        // make every subview frame an implicit animation whose completion
        // overwrites later layout.
        // Constraint animators ignore SwiftUI springs (they fall back to
        // AppKit's 0.25 s default), so this is the tokens' timed equivalent.
        // A toggle mid-animation starts from the constant on screen.
        Motion.sidebar.animateTimed(hidden ? .disappear : .appear, in: self, {
            Motion.animator(widthConstraint, in: self).constant = target
        }, completion: { [weak self] in
            guard let self, generation == self.animationGeneration else { return }
            self.widthCompletedGeneration = generation
            self.isWidthAnimating = false
            self.refreshHover()
            self.finishCollapseIfReady(generation: generation, hidden: hidden, fadesPanel: collapseMotion.fadesPanel)
        })

        // Keep the width's existing appear/disappear timing, but let the
        // prototype use the short fade tokens. This makes slideFade read as
        // a quick reveal over the structural slide instead of extending the
        // opacity animation to the sidebar's full travel time.
        if collapseMotion.fadesPanel {
            Motion.sidebar.animateTimed(hidden ? .fadeOut : .fadeIn, in: self, {
                panel.animator().alphaValue = hidden ? 0 : 1
            }, completion: { [weak self] in
                guard let self, generation == self.animationGeneration else { return }
                self.fadeCompletedGeneration = generation
                self.finishCollapseIfReady(generation: generation, hidden: hidden, fadesPanel: true)
            })
        }
    }

    /// A render-server slide's springs landed (the newest slide's): the width leg is done.
    func finishRenderSlide(generation: Int, hidden: Bool, fadesPanel: Bool) {
        guard generation == animationGeneration else { return }
        widthCompletedGeneration = generation
        renderSlideSprings = []
        isWidthAnimating = false
        refreshHover()
        finishCollapseIfReady(generation: generation, hidden: hidden, fadesPanel: fadesPanel)
    }

    /// A render-server slide's panel fade ended: the opacity leg is done.
    func finishRenderFade(generation: Int, hidden: Bool) {
        guard generation == animationGeneration else { return }
        fadeCompletedGeneration = generation
        finishCollapseIfReady(generation: generation, hidden: hidden, fadesPanel: true)
    }

    /// Hides a collapsed panel only after each active leg reaches its target.
    /// Width normally finishes last; the explicit gate also keeps Reduce
    /// Motion's instant width snap from racing the short opacity fade.
    private func finishCollapseIfReady(generation: Int, hidden: Bool, fadesPanel: Bool) {
        guard hidden, generation == animationGeneration, isPanelCollapsed,
              widthCompletedGeneration == generation,
              !fadesPanel || fadeCompletedGeneration == generation else { return }
        panel.alphaValue = fadesPanel ? 0 : 1
        panel.isHidden = true
        PointerHover.refresh(in: window)
    }
}
