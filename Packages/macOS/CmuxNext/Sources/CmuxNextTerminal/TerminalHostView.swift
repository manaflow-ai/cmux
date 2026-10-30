public import AppKit
import CmuxNextDesign
import CmuxNextTerminalFind
import Observation

/// Container the App embeds. Holds the current surface view (swapped on
/// replay) and paints the terminal's background (its theme's, else the
/// config's) behind an announced grid that is smaller than the view.
///
/// The surface fills the host, which fills the pane's content border, so
/// the first cell sits exactly Ghostty's padding inside the border
/// (`TerminalPadding.cmuxDefault` unless the user set their own).
public final class TerminalHostView: NSView {
    private weak var current: TerminalSurfaceView?
    /// The session's theme; nil paints the config background.
    var theme: GhosttyThemeConfig? {
        didSet { paintBackground() }
    }
    /// Shown over the last screen while the link is down (click-through).
    private let banner = TerminalStatusBanner()
    /// The scroller: thin, shown only while scrolling (SCROLLBARS-THIN).
    private let scroller = TerminalScroller()
    private var shownStatus: TerminalConnectionStatus = .connected
    private var hostLoss: TerminalHostLoss?
    private var hostLossCause: TerminalHostLossCause?
    private var shellStall: TerminalShellStall?
    /// "Restart Shell Here" above the banner while the shell has ended.
    /// It, Retry and the "Sized for" chip are built the first time they show, not with the
    /// terminal: each is a rounded NSButton, whose bezel is sized and laid out through SwiftUI,
    /// and a hidden chip's constraints conflict at its zero frame, all in a split's first frame.
    private var restartButton: TerminalRestartButton?
    /// "Retry" above the banner once the view's attach kept failing.
    private var retryButton: TerminalRetryButton?
    /// "Sized for <device>" with Take over, bottom-trailing, while another view sets the grid.
    private var sizedForChip: TerminalSizedForChip?
    private var restartAction: (@MainActor () -> Void)?
    /// The App's `tab.restart` for this tab; nil hides the button (a daemon
    /// without `tab-restart-v1`, a tab that cannot restart).
    public var onRestart: (@MainActor () -> Void)? {
        get { restartAction }
        set { restartAction = newValue; syncRestartButton(); needsLayout = true }
    }

    /// The first cell's top-left in this view's coordinates (top-left
    /// origin): Ghostty's leading and top padding, or with
    /// `window-padding-balance` half the grid's leftover (for `debug.pane_chrome`).
    public var firstCellOrigin: CGPoint {
        let padding = GhosttyRuntime.shared.terminalPadding
        guard padding.balanced, let model = current?.session?.model, let grid = model.grid, grid.columns > 0, grid.rows > 0 else {
            return CGPoint(x: padding.leading, y: padding.top)
        }
        let scale = window?.backingScaleFactor ?? 2
        let gridWidth = CGFloat(grid.columns) * model.cellPixelSize.width / scale
        let gridHeight = CGFloat(grid.rows) * model.cellPixelSize.height / scale
        let width = bounds.width - scroller.reservedWidth
        return CGPoint(x: max(padding.leading, (width - gridWidth) / 2), y: max(padding.top, (terminalBounds.height - gridHeight) / 2))
    }

    /// A view under the terminal (the App's TextBox composer): the full width at the bottom, at
    /// its fitting height, and the surface, the scroller and the overlays take the rest. A hidden
    /// accessory takes no room. Set the host's `needsLayout` when its height or visibility changes.
    public var bottomAccessory: NSView? {
        didSet {
            guard oldValue !== bottomAccessory else { return }
            oldValue?.removeFromSuperview()
            if let bottomAccessory {
                bottomAccessory.translatesAutoresizingMaskIntoConstraints = true // framed in layout()
                addSubview(bottomAccessory, positioned: .above, relativeTo: scroller)
            }
            needsLayout = true
        }
    }

    /// The accessory's height, 0 while there is none or it is hidden.
    private var accessoryHeight: CGFloat { accessoryHeight(forHostHeight: bounds.height) }

    /// The accessory's height in a host `height` points tall (at most all of it): a pane's spring measures
    /// it against the size the host will rest at, not the size it has now (a composer taller than a short pane).
    private func accessoryHeight(forHostHeight height: CGFloat) -> CGFloat {
        guard let bottomAccessory, !bottomAccessory.isHidden else { return 0 }
        return min(height, ceil(bottomAccessory.fittingSize.height))
    }

    /// The part of the host the terminal shows in: all of it, less the accessory's strip.
    private var terminalBounds: CGRect {
        let accessory = accessoryHeight
        return CGRect(x: bounds.minX, y: bounds.minY + accessory, width: bounds.width, height: max(0, bounds.height - accessory))
    }

    private var configObserver: (any NSObjectProtocol)?
    private var transparencyObserver: (any NSObjectProtocol)?
    /// Held here: scopes keep their responders weakly.
    private let aroundListener = TerminalHostThemeListener()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        // A surface frame of another size (the host-sized drawable before its
        // next draw) never draws past the host.
        layer?.masksToBounds = true
        paintBackground()
        // Frame layout (`layout()`), not Auto Layout: a pane resized every
        // frame of a drag solves no constraints here.
        addSubview(banner)
        addSubview(scroller, positioned: .below, relativeTo: banner)
        scroller.onStyleChange = { [weak self] in self?.needsLayout = true }
        scroller.onScrollToRow = { [weak self] row in _ = self?.current?.performBindingAction("scroll_to_row:\(row)") }
        scroller.onWheel = { [weak self] event in self?.current?.scrollWheel(with: event) }
        // A config reload can change window-padding-x.
        configObserver = NotificationCenter.default.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
        // Reduce Transparency turns the window opaque or see-through without a theme change.
        transparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer registered with queue: .main (OperationQueue.main runs on the main thread)
            MainActor.assumeIsolated { self?.paintBackground() }
        }
    }

    /// Pins the session's find bar to the top-trailing corner, above the
    /// surface and the status banner.
    /// The find bar is built the first time find opens, not with the
    /// terminal: its glass panel, stack and buttons cost about 5 ms of main
    /// thread per new terminal (R81 trace), most of a 120 Hz frame.
    func attachFind(_ find: TerminalFindController) {
        if find.isPresented { return installFindBar(find) }
        withObservationTracking {
            _ = find.isPresented
        } onChange: { [weak self, weak find] in
            Task { @MainActor in
                guard let self, let find else { return }
                self.attachFind(find)
            }
        }
    }

    private func installFindBar(_ find: TerminalFindController) {
        guard !subviews.contains(where: { $0 is TerminalFindBarView }) else { return }
        let bar = TerminalFindBarView(find: find)
        bar.translatesAutoresizingMaskIntoConstraints = true // framed in layout()
        addSubview(bar, positioned: .above, relativeTo: banner)
        needsLayout = true
    }

    /// The link status label over the terminal (hidden while connected).
    var statusText: String? {
        banner.isHidden ? nil : TerminalStatusBanner.text(for: shownStatus, hostLoss: hostLoss, cause: hostLossCause, stall: shellStall)
    }

    func showStatus(_ status: TerminalConnectionStatus) {
        shownStatus = status
        banner.show(status, hostLoss: hostLoss, cause: hostLossCause, stall: shellStall)
        syncRestartButton()
        if retryButton == nil, TerminalRetryButton.shows(status) {
            let button = TerminalRetryButton()
            // The same re-attach a click in the disconnected terminal starts.
            button.onRetry = { [weak self] in self?.current?.session?.surfaceClicked() }
            addOverlay(button)
            retryButton = button
        }
        retryButton?.show(status)
        needsLayout = true
    }

    /// Builds the restart button once the shell has ended and the App gave an action.
    private func syncRestartButton() {
        if restartButton == nil, shownStatus == .exited, restartAction != nil {
            let button = TerminalRestartButton()
            addOverlay(button)
            restartButton = button
        }
        restartButton?.onRestart = restartAction
        restartButton?.show(shownStatus)
    }

    /// Above the status banner, as the find bar is.
    private func addOverlay(_ view: NSView) {
        addSubview(view, positioned: .above, relativeTo: banner)
    }

    /// The "Sized for" chip's text, nil while hidden (diagnostics and tests).
    var sizedForText: String? {
        sizedForChip?.shown.map { TerminalSizedForChip.text(for: $0) }
    }

    func showSizedFor(_ sizedFor: TerminalSizedFor?) {
        guard sizedFor != sizedForChip?.shown else { return }
        if sizedForChip == nil {
            let chip = TerminalSizedForChip()
            chip.onTakeOver = { [weak self] setLatest in self?.current?.session?.takeOverSize(setLatest: setLatest) }
            addOverlay(chip)
            sizedForChip = chip
        }
        sizedForChip?.show(sizedFor)
        needsLayout = true
    }

    func showHostLoss(_ loss: TerminalHostLoss?, cause: TerminalHostLossCause?) {
        hostLoss = loss
        hostLossCause = cause
        banner.show(shownStatus, hostLoss: loss, cause: cause, stall: shellStall)
        needsLayout = true
    }

    /// A shell the daemon cannot reach is labeled even while the view's link is up.
    func showShellStall(_ stall: TerminalShellStall?) {
        shellStall = stall
        banner.show(shownStatus, hostLoss: hostLoss, cause: hostLossCause, stall: stall)
        needsLayout = true
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            if let transparencyObserver { NSWorkspace.shared.notificationCenter.removeObserver(transparencyObserver) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func install(_ surfaceView: TerminalSurfaceView) {
        let old = current
        surfaceView.autoresizingMask = []
        surfaceView.frame = surfaceFrame
        // Below the scroller and the status banner, which stay over every swapped-in surface.
        addSubview(surfaceView, positioned: .below, relativeTo: scroller)
        current = surfaceView
        old?.removeFromSuperview()
        followScrollbar(of: surfaceView)
    }

    /// Shows the surface's scrollbar state (Ghostty's scrollbar action) on the scroller, now and on
    /// every change, while the surface is the current one.
    private func followScrollbar(of surfaceView: TerminalSurfaceView) {
        guard current === surfaceView, let model = surfaceView.session?.model else { return }
        let bar = withObservationTracking { model.scrollbar } onChange: { [weak self, weak surfaceView] in
            Task { @MainActor in
                guard let self, let surfaceView else { return }
                self.followScrollbar(of: surfaceView)
            }
        }
        scroller.update(bar)
    }

    /// The width a surface gets in a host `hostWidth` points wide (less a legacy scroller's strip),
    /// for working out a terminal's grid before its host exists.
    public static func surfaceWidth(hostWidth: CGFloat) -> CGFloat {
        let reserved = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return max(0, hostWidth - reserved)
    }

    /// The surface's frame: the host, less a legacy scroller's strip (none: the scroller is overlay). While
    /// a pane's layout spring runs, the surface keeps the size it will rest at (``holdSurface(size:anchor:)``),
    /// pinned to the area's top or bottom edge; the host clips it and paints the terminal background beside it.
    private var surfaceFrame: CGRect {
        let area = terminalBounds
        if let hold = surfaceHold {
            let y = hold.anchor == .bottom ? area.minY : area.maxY - hold.size.height
            return CGRect(x: area.minX, y: y, width: hold.size.width, height: hold.size.height)
        }
        return CGRect(x: area.minX, y: area.minY, width: max(0, area.width - scroller.reservedWidth), height: area.height)
    }

    /// The size the surface takes in a host of `hostSize` points: less the accessory's strip and a legacy
    /// scroller's.
    func surfaceSize(forHostSize hostSize: CGSize) -> CGSize {
        CGSize(width: max(0, hostSize.width - scroller.reservedWidth), height: max(0, hostSize.height - accessoryHeight(forHostHeight: hostSize.height)))
    }

    /// The surface's size and edge while its pane's layout spring runs; nil at rest.
    private var surfaceHold: (size: CGSize, anchor: PaneMotionAnchor)?

    /// Keeps the surface at `size`, the size it will have when its pane's layout spring lands (a split or a
    /// close, Lawrence 2026-10-23): the terminal draws its final grid on every frame of the spring and reflows
    /// once, not once per frame. `anchor`: the edge it rides (the bottom keeps a prompt on the last row in view).
    func holdSurface(size: CGSize, anchor: PaneMotionAnchor) {
        surfaceHold = (size, anchor)
        if let current, current.frame != surfaceFrame { current.frame = surfaceFrame }
    }

    /// The spring landed: the surface takes the host's area again (the same size, unless the landing differs).
    func releaseSurfaceHold() {
        guard surfaceHold != nil else { return }
        surfaceHold = nil
        if let current, current.frame != surfaceFrame { current.frame = surfaceFrame }
    }

    public override func layout() {
        super.layout()
        if let current, current.frame != surfaceFrame { current.frame = surfaceFrame }
        let strip = scroller.strip(in: terminalBounds)
        if scroller.frame != strip { scroller.frame = strip }
        if let bottomAccessory, !bottomAccessory.isHidden {
            let frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: accessoryHeight)
            if bottomAccessory.frame != frame { bottomAccessory.frame = frame }
        }
        layoutOverlays()
    }

    /// The status banner centered 12 pt above the bottom (at most the width
    /// less 24), the restart and retry buttons centered 8 pt above it, and
    /// the find bar in the top-trailing corner. Hidden ones are skipped.
    private func layoutOverlays() {
        let buttons: [NSView] = ([restartButton, retryButton] as [NSButton?]).compactMap { $0 }.filter { !$0.isHidden }
        if !banner.isHidden || !buttons.isEmpty {
            layoutStatus(buttons: buttons)
        }
        let inset = Metrics.panelInset
        if let sizedForChip, !sizedForChip.isHidden {
            // Bottom-trailing, clear of the scroller: where a padded grid leaves room.
            let trailing = bounds.width - scroller.reservedWidth - inset
            _ = place(sizedForChip, maxWidth: bounds.width - inset * 2) { size in
                CGPoint(x: max(inset, trailing - size.width), y: self.terminalBounds.minY + inset)
            }
        }
        // Framed hidden too: the bar shows itself when find opens.
        // The shared find pill sits where every pane's does (FindPillMetrics.inset from top and trailing).
        let findInset = FindPillMetrics.inset
        for case let bar as TerminalFindBarView in subviews {
            _ = place(bar, maxWidth: bounds.width - findInset * 2, evenHidden: true) { size in
                CGPoint(x: self.bounds.width - findInset - size.width, y: self.bounds.height - findInset - size.height)
            }
        }
    }

    private func layoutStatus(buttons: [NSView]) {
        let banner = place(self.banner, maxWidth: bounds.width - 24) { size in
            CGPoint(x: (self.bounds.width - size.width) / 2, y: self.terminalBounds.minY + 12)
        }
        for button in buttons {
            _ = place(button, maxWidth: bounds.width) { size in
                CGPoint(x: (self.bounds.width - size.width) / 2, y: banner.maxY + 8)
            }
        }
    }

    /// Sizes `view` to its fitting size (no wider than `maxWidth`) at
    /// `origin`; returns its frame (the banner's, even while hidden, which
    /// places the buttons above where it shows).
    private func place(_ view: NSView, maxWidth: CGFloat, evenHidden: Bool = false, origin: (CGSize) -> CGPoint) -> CGRect {
        let fitting = view.fittingSize
        let size = CGSize(width: max(0, min(fitting.width, maxWidth)), height: fitting.height)
        let frame = CGRect(origin: origin(size), size: size).integral
        if !view.isHidden || evenHidden, view.frame != frame { view.frame = frame }
        return frame
    }

    /// Anything that lands on the host itself goes to the surface.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self, let current else { return hit }
        return current
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintBackground()
    }

    /// The host roots its terminal's scope, so the panes' repaint stops here: it listens to the
    /// scope it sits in, whose colors decide whether its own theme shows (`paintBackground`).
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        aroundListener.host = self
        superview?.themeScope.addResponder(aroundListener)
        paintBackground()
    }

    /// An opaque window paints the terminal's theme background, like
    /// `GhosttyRuntime.backgroundColor`. Where the window is see-through
    /// (translucent, glass, or over art) the window root paints the one
    /// sheet and the host stays clear, as the panes around it do, unless the
    /// terminal's theme differs from theirs: its background then lies over
    /// the glass at the window's tint (`WindowBackdrop.tintOpacity`). The user's terminal
    /// background (`appearance.surfaces.terminal`) replaces all of these;
    /// the surfaces then draw a transparent default background.
    fileprivate func paintBackground() {
        let (scope, tokens) = (themeScope, themeTokens)
        // The window root's backdrop (`WindowRootView.backdrop`): the scope's art and its own tint.
        let backdrop = WindowBackdrop(tokens, reduceTransparency: ReduceTransparency.shared.isEnabled,
                                      selection: scope.backdropSelection, tintOpacity: scope.backdropTintOpacity)
        GhosttyRuntime.setSeeThrough(superview != nil && !backdrop.panesPaintBackground, host: self)
        let fill = performWithTheme { Palette.surfaceOverride(.terminal) }
        if let fill {
            layer?.backgroundColor = fill.cgColor
            return
        }
        guard !backdrop.panesPaintBackground else {
            guard let rgb = theme?.colors?.background else {
                layer?.backgroundColor = GhosttyRuntime.shared.backgroundColor.cgColor
                return
            }
            layer?.backgroundColor = CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
            return
        }
        let around = superview?.themeTokens.surfaceBackground.withAlpha(1)
        let own = tokens.surfaceBackground.withAlpha(1)
        layer?.backgroundColor = theme == nil || own == around ? nil : own.withAlpha(backdrop.tintOpacity).cgColor
    }
}

/// Repaints a host when the scope around it changes its colors or its art.
@MainActor
private final class TerminalHostThemeListener: ThemeResponsive {
    weak var host: TerminalHostView?

    func themeDidChange() { host?.paintBackground() }
}
