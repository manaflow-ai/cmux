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
    public var tracksWindowOcclusion = false {
        didSet { if tracksWindowOcclusion != oldValue { observeOcclusion() } }
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

    private func refresh() {
        var config = StatusIndicatorAppearance.shared.config
        if ignoresScaleSetting { config.settings.scale = 1 }
        let animates = window != nil && isWindowVisible && config.animatesLoops
        let plan = StatusIndicatorPlan.make(state, style: config.style(hint: styleHint), animates: animates, set: config.iconSet,
                                            isStatic: config.isStatic, staticShapes: config.staticShapes)
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

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
    }

    private func stopObservingOcclusion() {
        if let occlusionObserver { occlusionObserver.center.removeObserver(occlusionObserver.token) }
        occlusionObserver = nil
    }
}
