public import AppKit
public import CmuxNextDesignTokens
import CmuxNextWakeups

/// The cmux mark on a launch window's glass while its content area waits for its data
/// (`LaunchReveal`), as other desktop apps show theirs (Leo, 2026-11-16: "do we have an initial
/// load logo fade in glass thing like how [a chat app] has theirs/[an issue tracker] has a thing").
///
/// Instant first: the mark never holds, delays or gates a region. A window whose content shows by
/// its first frame (a relaunch's saved terminal frames, a page, Home's saved page) never makes the
/// mark, and one whose content comes within `MotionTunables.launchMarkDelay` never shows it. Once
/// shown, it fades out in the turn the content fades in (a crossfade), and leaves after its fade.
///
/// Only the content area counts (`contentRegions`), and only while a view of it is held: the
/// connecting state holds none, so it keeps its empty main pane (cx-r650e), and the sidebar comes
/// in on its own (from the first frame on a fresh profile: FreshLaunchSidebarTests).
@MainActor
public final class LaunchGlassMark {
    /// The regions of a window's content area: a workspace's panes, or Home.
    public static let contentRegions: Set<LaunchRegion> = [.pane, .home]

    private weak var host: NSView?
    private let reveal: LaunchReveal
    private let delay: DemandTimer
    private let removal: DemandTimer
    private let style: @MainActor () -> LaunchGlassReveal
    private let onMark: @MainActor (String) -> Void
    private var started = false
    /// The content showed or the window closed: a delay already on its way to `show` finds this.
    private var ended = false
    /// The mark on the glass, from its reveal until its fade-out ends.
    public private(set) var view: LaunchGlassMarkView?

    /// - Parameters:
    ///   - host: The window's content area; the mark covers it, centered, above its content.
    ///   - clock: The delay's and the removal's clock (tests pass a manual one).
    ///   - style: The reveal, read when the mark shows (`launch.reveal`).
    ///   - onMark: Gets `launch_mark.shown` and `launch_mark.concealed` (the app's launch marks).
    public init(host: NSView, reveal: LaunchReveal = .shared, clock: any Clock<Duration> = ContinuousClock(),
                style: @escaping @MainActor () -> LaunchGlassReveal = { LaunchGlassReveal.tunable.value },
                onMark: @escaping @MainActor (String) -> Void = { _ in }) {
        self.host = host
        self.reveal = reveal
        delay = DemandTimer(owner: "launch.glass-mark", clock: clock)
        removal = DemandTimer(owner: "launch.glass-mark.removal", clock: clock)
        self.style = style
        self.onMark = onMark
    }

    /// Makes and starts the mark for `host`'s window as it is ordered in for its first frame. It keeps itself
    /// until its content shows (the region's deadline bounds that), so the window needs no handle on it; a window
    /// closed first leaves the mark on its detached content, gone with it.
    @discardableResult
    public static func start(on host: NSView, reveal: LaunchReveal, onMark: @escaping @MainActor (String) -> Void) -> LaunchGlassMark {
        let mark = LaunchGlassMark(host: host, reveal: reveal, onMark: onMark)
        mark.start(keepsItself: true)
        return mark
    }

    /// Whether the mark waits for its delay.
    public var isPending: Bool { delay.isScheduled }

    /// Decides once, when the window is ordered in for its first frame: nothing at all when its
    /// content area shows (or holds nothing); otherwise the mark after the delay, unless the
    /// content shows first.
    /// `keepsItself`: the content's `whenShowing` work holds the mark until it runs (`start(on:)`).
    public func start(keepsItself: Bool = false) {
        guard !started else { return }
        started = true
        guard style().markStyle != nil, let window = host?.window else { return }
        let regions = reveal.waitingRegions(Self.contentRegions, in: window)
        guard !regions.isEmpty else { return }
        delay.schedule(after: .seconds(MotionTunables.launchMarkDelay.value)) { @MainActor [weak self] in self?.show() }
        if keepsItself {
            reveal.whenShowing(regions, in: window) { self.yield() }
        } else {
            reveal.whenShowing(regions, in: window) { [weak self] in self?.yield() }
        }
    }

    private func show() {
        guard !ended, let host, let markStyle = style().markStyle else { return }
        let view = LaunchGlassMarkView(frame: host.bounds)
        view.autoresizingMask = [.width, .height]
        host.addSubview(view, positioned: .above, relativeTo: nil)
        self.view = view
        view.reveal(markStyle)
        onMark("launch_mark.shown")
    }

    /// The content shows: the mark fades out in this turn, beside the content's fade-in.
    private func yield() {
        ended = true
        delay.cancel()
        guard let view, view.isRevealed else { return }
        view.conceal()
        onMark("launch_mark.concealed")
        let fade = Motion.panes.duration(.fadeOut)
        guard fade > 0 else { return remove() }
        removal.schedule(after: .seconds(fade)) { @MainActor [weak self] in self?.remove() }
    }

    private func remove() {
        view?.removeFromSuperview()
        view = nil
    }

    /// The window closed: nothing more shows, and a mark on screen leaves now.
    public func teardown() {
        ended = true
        delay.cancel()
        removal.cancel()
        remove()
    }
}

/// The launch mark over a window's content area (`LaunchGlassMark`): the chevron centered, on a
/// glass tile for `lens`. It takes no clicks and is no accessibility element.
@MainActor
public final class LaunchGlassMarkView: NSView {
    /// The `lens` tile's side.
    public static let tileSide: CGFloat = 64

    public let mark = LaunchMarkView(frame: .zero)
    /// The `lens` style's glass tile (nil for the other styles).
    public private(set) var tile: GlassPanelView?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(mark)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        let size = mark.intrinsicContentSize
        mark.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                            width: size.width, height: size.height)
        tile?.frame = NSRect(x: (bounds.midX - Self.tileSide / 2).rounded(), y: (bounds.midY - Self.tileSide / 2).rounded(),
                             width: Self.tileSide, height: Self.tileSide)
    }

    /// Resolves the mark in with `style`; `lens` fades its tile in with it.
    public func reveal(_ style: LaunchMarkStyle) {
        if style == .lens, tile == nil {
            let tile = Glass.makePanel(style: .clear, cornerRadius: Metrics.surfaceCornerRadius, interactive: false)
            tile.translatesAutoresizingMaskIntoConstraints = true
            tile.wantsLayer = true
            addSubview(tile, positioned: .below, relativeTo: mark)
            self.tile = tile
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        mark.reveal(style)
        if let layer = tile?.layer { Motion.panes.revealLaunchBacking(layer) }
    }

    /// Fades the mark (and its tile) out; a `sheen` sweep stops here.
    public func conceal() {
        mark.conceal()
        guard let tile, let layer = tile.layer else { return }
        // The model value at once (AppKit keeps the layer's opacity from it); the fade runs on the layer.
        tile.alphaValue = 0
        Motion.panes.concealLaunchBacking(layer)
    }

    /// Whether the mark shows.
    public var isRevealed: Bool { mark.isRevealed }
}
