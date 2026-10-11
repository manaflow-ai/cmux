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

    public override var wantsUpdateLayer: Bool { true }

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
    }

    private func refresh() {
        let config = StatusIndicatorAppearance.shared.config
        let animates = window != nil && isWindowVisible && config.animatesLoops
        let plan = StatusIndicatorPlan.make(state, style: config.style(hint: styleHint), animates: animates, set: config.iconSet)
        let showed = showsGlyph
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
        if let window { isWindowVisible = window.occlusionState.contains(.visible) }
        refresh()
    }
}
