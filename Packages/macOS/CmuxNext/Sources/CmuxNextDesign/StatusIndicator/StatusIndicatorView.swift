public import AppKit
import CmuxNextCompat
public import CmuxNextDesignTokens

/// `StatusIndicatorLayer` in an NSView, for view-based hosts (sidebar rows,
/// group headers, section items, Home, pane headers). Follows the shared
/// config live, resolves colors in its theme scope, and stops animating
/// while its window is occluded, off screen or under Reduce Motion.
public final class StatusIndicatorView: NSView, StatusIndicatorConfigClient, WindowOcclusionFollowing {
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
        didSet { if tracksWindowOcclusion != oldValue { followOcclusion(of: window) } }
    }

    /// Draws at the host's size whatever `appearance.statusIndicator.scale` says (chrome spinners
    /// sized to their slot); the color still follows the setting.
    public var ignoresScaleSetting = false {
        didSet { if ignoresScaleSetting != oldValue { refresh() } }
    }

    /// The window family it follows while `tracksWindowOcclusion` is on and it is in a window: one
    /// observer per window, not one per spinner (PATTERNS.md P3).
    private weak var occlusionFamily: WindowOcclusionFamily?

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

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        if owesResync, !isHiddenOrHasHiddenAncestor { statusIndicatorResync() }
    }

    private func refresh() {
        var config = StatusIndicatorAppearance.shared.config
        if ignoresScaleSetting { config.settings.scale = 1 }
        // A host's hidden flag that went stale (its "visible" notice missed this row) cannot keep a
        // row on a visible window still: the window's own state wins when it says visible.
        let visible = isWindowVisible || window?.occlusionState.contains(.visible) == true
        let animates = window != nil && visible && config.animatesLoops
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
            indicator.colors = .current(loading: StatusIndicatorAppearance.shared.config.settings.color)
        }
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow !== window else { return }
        followOcclusion(of: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owesResync = false
        if let window { isWindowVisible = window.occlusionState.contains(.visible) }
        refresh()
    }

    /// Its window was covered, minimized, ordered out or came back (only while
    /// `tracksWindowOcclusion` is on): a window that shows after the view moved into it starts
    /// the animation.
    public func windowOcclusionDidChange() {
        guard let window else { return }
        isWindowVisible = window.occlusionState.contains(.visible)
    }

    /// Follows the family of `target` while `tracksWindowOcclusion` is on, and none otherwise.
    private func followOcclusion(of target: NSWindow?) {
        let family = tracksWindowOcclusion ? target.map { WindowOcclusionFamily.of($0) } : nil
        guard family !== occlusionFamily else { return }
        occlusionFamily?.remove(self)
        occlusionFamily = family
        family?.add(self)
    }
}
