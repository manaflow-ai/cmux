public import AppKit

/// `StatusIndicatorLayer` in an NSView, for view-based hosts (sidebar rows,
/// group headers, section items, Home, pane headers). Follows the shared
/// config live, resolves colors in its theme scope, and stops animating
/// while its window is occluded, off screen or under Reduce Motion.
public final class StatusIndicatorView: NSView, StatusIndicatorConfigClient {
    public let indicator = StatusIndicatorLayer()
    public private(set) var state: StatusIndicatorState = .idle
    /// The reporter's style hint (`cmux status set --style`); nil uses the
    /// setting.
    public private(set) var styleHint: StatusIndicatorStyle?

    /// Whether the window is on screen and not fully covered. Hosts that
    /// already track occlusion (the sidebar list) set it; otherwise the view
    /// reads it when it moves to a window.
    public var isWindowVisible = true {
        didSet { if isWindowVisible != oldValue { refresh() } }
    }

    /// Whether the view follows its own window's occlusion (chrome spinners whose host tracks
    /// none, `spinner()`). Off for hosts that set `isWindowVisible` themselves (the sidebar list).
    /// Only a shown view listens (in a window, no hidden flag of its own or an ancestor's: an idle
    /// indicator hides itself); it reads its window's state when it shows, so an occlusion change
    /// costs the indicators on screen, not every row of the session (perf-lead.md cause 6).
    public var tracksWindowOcclusion = false {
        didSet {
            guard tracksWindowOcclusion != oldValue else { return }
            if observeOcclusion(), let window { isWindowVisible = window.occlusionState.contains(.visible) }
        }
    }

    /// Draws at the host's size whatever `appearance.statusIndicator.scale` says (chrome spinners
    /// sized to their slot); the color still follows the setting.
    public var ignoresScaleSetting = false {
        didSet { if ignoresScaleSetting != oldValue { refresh() } }
    }

    /// Where it hears of its window's occlusion (tests post to their own).
    public var notificationCenter: NotificationCenter = .default {
        didSet {
            guard notificationCenter !== oldValue else { return }
            stopObservingOcclusion()
            observeOcclusion()
        }
    }

    private var occlusionObserver: (token: any NSObjectProtocol, center: NotificationCenter)?
    private weak var observedWindow: NSWindow?
    /// The shared config and its resync moments (``StatusIndicatorAppearance/shared`` in the
    /// app; a test passes its own).
    private let appearance: StatusIndicatorAppearance
    /// The resync moment this view last checked itself at (``StatusIndicatorAppearance/resyncMoment``):
    /// a view off screen at a moment is not reached, and catches up when it shows.
    private var syncedMoment: UInt64

    public override convenience init(frame: NSRect) {
        self.init(frame: frame, appearance: .shared)
    }

    /// Creates an indicator that follows `appearance`'s config and resync moments.
    ///
    /// - Parameters:
    ///   - frame: The view's frame.
    ///   - appearance: Where the config and the resync moments come from (`.shared` in the app).
    public init(frame: NSRect, appearance: StatusIndicatorAppearance) {
        self.appearance = appearance
        syncedMoment = appearance.resyncMoment
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(indicator.layer)
        indicator.hostIsFlipped = isFlipped
        isHidden = true
        appearance.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // A window freed with the view still inside never moves the view out, so the occlusion token
    // goes here. cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an
    // action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { // main-proof: the guard above returns off the main thread
            if let occlusionObserver { occlusionObserver.center.removeObserver(occlusionObserver.token) }
        }
    }

    nonisolated public override var wantsUpdateLayer: Bool { true }

    /// Show `state`, drawn in `style` (nil: the configured style).
    public func configure(_ state: StatusIndicatorState, style: StatusIndicatorStyle? = nil) {
        guard state != self.state || style != styleHint || indicator.plan == .hidden && state.isVisible else { return }
        self.state = state
        styleHint = style
        refresh()
    }

    /// Whether `state` would draw anything with the current config (hosts
    /// reserve layout space only then).
    public var showsGlyph: Bool { indicator.plan.glyph != .none }

    public func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig) {
        refresh()
        needsDisplay = true
        // The static look can show or hide the mark; the host lays out again.
        superview?.needsLayout = true
    }

    /// Checks the indicator again (the app came back, a window became main, the Mac woke). The
    /// appearance calls only an indicator on screen (`followsResyncs`): an activation costs what
    /// shows, not every row and tab of the session (user 2026-10-21, Cmd-Tab lag with many
    /// workspaces). One off screen at the moment checks itself when it shows.
    public func statusIndicatorResync() {
        // Off screen (a stale member of the resync set): leave the moment owed so `viewDidUnhide`
        // catches up when the view shows, and leave the set.
        guard let window, !isHiddenOrHasHiddenAncestor else {
            updateResyncMembership()
            return
        }
        syncedMoment = appearance.resyncMoment
        appearance.noteResyncCheck()
        isWindowVisible = window.occlusionState.contains(.visible)
        refresh()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        observeOcclusion()
        updateResyncMembership()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        guard !isHiddenOrHasHiddenAncestor else { return }
        if observeOcclusion(), let window { isWindowVisible = window.occlusionState.contains(.visible) }
        // A moment passed while it was hidden (a parked workspace, a collapsed group): catch up once.
        if syncedMoment != appearance.resyncMoment { statusIndicatorResync() }
        updateResyncMembership()
    }

    /// The config this view draws with.
    private var drawnConfig: StatusIndicatorConfig {
        var config = appearance.config
        if ignoresScaleSetting { config.settings.scale = 1 }
        return config
    }

    /// Whether the resync moments reach this view: on screen (in a window, no hidden flag of its
    /// own or an ancestor's; an idle indicator hides itself).
    private var followsResyncs: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// Keeps the resync set current. AppKit sends `viewDidHide`/`viewDidUnhide` whenever
    /// `isHiddenOrHasHiddenAncestor` flips, also when the view or an ancestor is inserted under a
    /// hidden or shown parent (NSView docs), so the hide notices, `viewDidMoveToWindow` and
    /// `refresh` cover every way the view goes on or off screen.
    private func updateResyncMembership() {
        appearance.setFollowsResyncs(self, follows: followsResyncs)
    }

    /// Applies the plan for the state, config and window visibility. Lays out and redraws only
    /// when the plan or config changed (`force`: the view moved to another window): a resync of
    /// an indicator that already shows the right thing costs no layout and no redraw.
    private func refresh(force: Bool = false) {
        let config = drawnConfig
        // A host's hidden flag that went stale (its "visible" notice missed this row) cannot keep a
        // row on a visible window still: the window's own state wins when it says visible.
        let visible = isWindowVisible || window?.occlusionState.contains(.visible) == true
        let animates = window != nil && visible && config.animatesLoops
        let plan = StatusIndicatorPlan.make(state, style: config.style(hint: styleHint), animates: animates, set: config.iconSet,
                                            isStatic: config.isStatic, staticShapes: config.staticShapes,
                                            working: config.workingLook)
        let changed = force || plan != indicator.plan || config != indicator.config
        let showed = showsGlyph
        nameState()
        indicator.apply(plan, config: config)
        // An indicator hidden by its own idle state draws nothing a moment could repair, and one it
        // shows now draws the plan just made: both are current. Without this, an idle row that went
        // busy after any activation ran a second, reentrant refresh from `viewDidUnhide`.
        if isHidden || plan.glyph == .none { syncedMoment = appearance.resyncMoment }
        isHidden = plan.glyph == .none
        // The host reserves trailing space only for a visible glyph.
        if showed != showsGlyph { superview?.needsLayout = true }
        updateResyncMembership()
        guard changed else { return }
        needsLayout = true
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        indicator.contentsScale = window?.backingScaleFactor ?? 2
        if indicator.frame == bounds { indicator.relayout() } else { indicator.frame = bounds }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    public override func updateLayer() {
        performWithTheme {
            indicator.colors = .current(loading: appearance.config.settings.color)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Reads its new window's state now: nothing owed from before.
        syncedMoment = appearance.resyncMoment
        observeOcclusion()
        if let window { isWindowVisible = window.occlusionState.contains(.visible) }
        refresh(force: true)
    }

    /// Watches the current window's occlusion while `tracksWindowOcclusion` is on and the view
    /// shows; a window that shows after the view moved into it starts the animation. Returns
    /// whether it started watching now (the caller reads the state it missed).
    @discardableResult
    private func observeOcclusion() -> Bool {
        let target = tracksWindowOcclusion && !isHiddenOrHasHiddenAncestor ? window : nil
        guard observedWindow !== target || (target != nil) != (occlusionObserver != nil) else { return false }
        stopObservingOcclusion()
        observedWindow = target
        guard let target else { return false }
        let token = notificationCenter.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: target, queue: .main
        ) { [weak self] _ in
            // main-proof: the observer runs on the main queue (queue: .main)
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.isWindowVisible = window.occlusionState.contains(.visible)
            }
        }
        occlusionObserver = (token, notificationCenter)
        return true
    }

    private func stopObservingOcclusion() {
        if let occlusionObserver { occlusionObserver.center.removeObserver(occlusionObserver.token) }
        occlusionObserver = nil
    }
}
