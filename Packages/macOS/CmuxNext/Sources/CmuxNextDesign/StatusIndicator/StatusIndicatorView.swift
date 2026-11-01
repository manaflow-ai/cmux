public import AppKit
import CmuxNextCompat
public import CmuxNextDesignTokens

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
    public var tracksWindowOcclusion = false {
        didSet { if tracksWindowOcclusion != oldValue { observeOcclusion() } }
    }

    /// Draws at the host's size whatever `appearance.statusIndicator.scale` says (chrome spinners
    /// sized to their slot); the color still follows the setting.
    public var ignoresScaleSetting = false {
        didSet { if ignoresScaleSetting != oldValue { refresh() } }
    }

    /// Draws unread, needs attention and errors in the system blue, orange and red
    /// (``StatusIndicatorLayer/Colors/status(loading:)``) instead of the theme's: the sidebar's
    /// rows and headers (Lawrence msg 11983).
    public var usesStatusColors = false {
        didSet { if usesStatusColors != oldValue { needsDisplay = true } }
    }

    /// Where it hears of its window's occlusion (tests post to their own).
    public var notificationCenter: NotificationCenter = .default {
        didSet {
            guard notificationCenter !== oldValue else { return }
            stopObservingOcclusion()
            observeOcclusion()
        }
    }

    private var occlusionObserver: MainActorObservation?
    private weak var observedWindow: NSWindow?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(indicator.layer)
        indicator.hostIsFlipped = isFlipped
        isHidden = true
        StatusIndicatorAppearance.shared.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

    /// A resync arrived while the view was out of a window or hidden (its own flag or an
    /// ancestor's: a parked workspace, a collapsed group); it runs when the view shows again.
    private var owesResync = false

    /// Checks the indicator again (the app came back, a window became main, the Mac woke). Only
    /// an indicator on screen does the work now: an activation costs what shows, not every row
    /// and tab of the session (user 2026-10-21, Cmd-Tab lag with many workspaces).
    public func statusIndicatorResync() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            owesResync = true
            return
        }
        owesResync = false
        StatusIndicatorAppearance.resyncs &+= 1
        if let window { isWindowVisible = window.occlusionState.contains(.visible) }
        refresh()
    }

    /// An ancestor was hidden at the last refresh (a parked pane or workspace, a collapsed group), so
    /// the loop was left off; showing it again starts the loop.
    private var hiddenByAncestor = false

    private var ancestorIsHidden: Bool { superview?.isHiddenOrHasHiddenAncestor == true }

    /// An ancestor hid this view: its loop stops. Hosts that push `isWindowVisible` (the sidebar list,
    /// the tab strip) already stop theirs; this covers an indicator inside a pane (the agent pane's
    /// loading mark), which is hidden in place when its tab or workspace parks (hq#3716). Only a view
    /// with a running loop does any work, so parking a workspace costs its spinning indicators alone.
    public override func viewDidHide() {
        super.viewDidHide()
        if indicator.runningAnimation != nil, ancestorIsHidden { refresh() }
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        if owesResync, !isHiddenOrHasHiddenAncestor {
            statusIndicatorResync()
        } else if hiddenByAncestor, !ancestorIsHidden {
            refresh()
        }
    }

    private func refresh() {
        var config = StatusIndicatorAppearance.shared.config
        if ignoresScaleSetting { config.settings.scale = 1 }
        // A host's hidden flag that went stale (its "visible" notice missed this row) cannot keep a
        // row on a visible window still: the window's own state wins when it says visible.
        let visible = isWindowVisible || window?.occlusionState.contains(.visible) == true
        // The view's own isHidden follows its glyph (below); only an ancestor's hides it from view.
        hiddenByAncestor = ancestorIsHidden
        let animates = window != nil && visible && !hiddenByAncestor && config.animatesLoops
        let plan = StatusIndicatorPlan.make(state, style: config.style(hint: styleHint), animates: animates, set: config.iconSet,
                                            isStatic: config.isStatic, staticShapes: config.staticShapes,
                                            working: config.workingLook)
        let showed = showsGlyph
        nameState()
        indicator.apply(plan, config: config)
        isHidden = plan.glyph == .none
        // The host reserves trailing space only for a visible glyph.
        if showed != showsGlyph { superview?.needsLayout = true }
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
            let loading = StatusIndicatorAppearance.shared.config.settings.color
            indicator.colors = usesStatusColors ? .status(loading: loading) : .current(loading: loading)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owesResync = false
        observeOcclusion()
        if let window { isWindowVisible = window.occlusionState.contains(.visible) }
        refresh()
    }

    /// Watches the current window's occlusion while `tracksWindowOcclusion` is on; a window that
    /// shows after the view moved into it starts the animation.
    private func observeOcclusion() {
        let target = tracksWindowOcclusion ? window : nil
        guard observedWindow !== target || (target != nil) != (occlusionObserver != nil) else { return }
        stopObservingOcclusion()
        observedWindow = target
        guard let target else { return }
        let token = MainActorObservation(NSWindow.didChangeOcclusionStateNotification, object: target, center: notificationCenter) { [weak self] in
            guard let self, let window = self.window else { return }
            self.isWindowVisible = window.occlusionState.contains(.visible)
        }
        occlusionObserver = token
    }

    private func stopObservingOcclusion() {
        occlusionObserver = nil
    }
}
