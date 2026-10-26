public import AppKit
import CmuxNextCompat
public import CmuxNextDesignTokens
public import CmuxNextWakeups

/// `StatusIndicatorLayer` in an NSView, for view-based hosts (sidebar rows,
/// group headers, section items, Home, pane headers). Follows the shared
/// config live, resolves colors in its theme scope, and animates only while
/// its ``visibilityNode`` is visible and Reduce Motion is off.
///
/// The node sits under its window's node (``WindowVisibilitySource``), and its own state is AppKit's
/// hidden state for the view (recipe R-hide, plans/cmux-next/chrome-parity/p06-scheduler.md). A
/// hidden app, a miniaturized or occluded window, a parked workspace and a hidden ancestor all reach
/// it as one flip; the view observes no window and walks no ancestors. Chromium paces a hidden
/// WebContents the same way, from the one visibility its owner sets
/// (`content/public/browser/visibility.h`, `WebContentsImpl::UpdateWebContentsVisibility`).
public final class StatusIndicatorView: NSView, StatusIndicatorConfigClient {
    public let indicator = StatusIndicatorLayer()
    public private(set) var state: StatusIndicatorState = .idle
    /// The reporter's style hint (`cmux status set --style`); nil uses the
    /// setting.
    public private(set) var styleHint: StatusIndicatorStyle?

    /// This indicator in the visibility tree. Its loop runs only while the node is visible.
    public let visibilityNode: VisibilityNode

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

    /// The parent of ``visibilityNode`` while the view is in no window: always hidden.
    private let offWindow: VisibilityNode
    private var flips: VisibilitySubscription?

    /// The key of the resync a hidden indicator owes (``statusIndicatorResync()``).
    private static let resyncKey = "StatusIndicatorView.resync"

    public override init(frame: NSRect) {
        let offWindow = VisibilityNode(root: "statusIndicator.offWindow", own: .hidden)
        self.offWindow = offWindow
        visibilityNode = VisibilityNode("statusIndicator", own: .hidden, parent: offWindow)
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(indicator.layer)
        indicator.hostIsFlipped = isFlipped
        isHidden = true
        flips = visibilityNode.subscribe(owner: "StatusIndicatorView") { [weak self] _ in self?.applyPlan() }
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

    /// Checks the indicator again (the app came back, a window became main, the Mac woke). Only
    /// an indicator whose node is visible does the work now; a hidden one does it once when it
    /// shows: an activation costs what shows, not every row and tab of the session (user
    /// 2026-10-21, Cmd-Tab lag with many workspaces).
    public func statusIndicatorResync() {
        visibilityNode.deferUntilVisible(key: Self.resyncKey) { [weak self] in
            guard let self else { return }
            StatusIndicatorAppearance.resyncs &+= 1
            refresh()
        }
    }

    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    /// The shared config, at the host's size when ``ignoresScaleSetting`` is on.
    private var currentConfig: StatusIndicatorConfig {
        var config = StatusIndicatorAppearance.shared.config
        if ignoresScaleSetting { config.settings.scale = 1 }
        return config
    }

    private func plan(_ config: StatusIndicatorConfig, animates: Bool) -> StatusIndicatorPlan {
        StatusIndicatorPlan.make(state, style: config.style(hint: styleHint), animates: animates, set: config.iconSet,
                                 isStatic: config.isStatic, staticShapes: config.staticShapes,
                                 working: config.workingLook)
    }

    private func refresh() {
        let config = currentConfig
        let showed = showsGlyph
        nameState()
        // Shown or hidden before the plan applies, so AppKit's unhide reaches ``visibilityNode`` and the
        // loop starts in this pass (whether a glyph shows does not depend on the loop).
        isHidden = plan(config, animates: false).glyph == .none
        applyPlan(config)
        // The host reserves trailing space only for a visible glyph.
        if showed != showsGlyph { superview?.needsLayout = true }
        needsLayout = true
        needsDisplay = true
    }

    /// Applies the plan with its loop only while ``visibilityNode`` is visible: a hidden indicator
    /// keeps no animation in the render server.
    private func applyPlan(_ given: StatusIndicatorConfig? = nil) {
        let config = given ?? currentConfig
        indicator.apply(plan(config, animates: visibilityNode.isVisible && config.animatesLoops), config: config)
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
        // The new place is read below; a resync owed to the old one is moot.
        visibilityNode.cancelDeferred(key: Self.resyncKey)
        placeInTree()
        refresh()
    }

    /// Puts ``visibilityNode`` under the window's node, or under the hidden root while the view is in
    /// no window.
    private func placeInTree() {
        let parent = window.map { WindowVisibilitySource.of($0).node } ?? offWindow
        do {
            try visibilityNode.attach(to: parent)
        } catch {
            assertionFailure("StatusIndicatorView: \(parent.name) cannot hold the indicator's node (\(error))")
        }
    }
}
