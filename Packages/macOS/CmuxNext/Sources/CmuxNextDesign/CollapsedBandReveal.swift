public import AppKit
import CmuxNextDesignTokens
public import CmuxNextWakeups

/// Opens the collapsed toolbar band (sidebar toggle, Back, Forward) while
/// the sidebar is hidden and the top-left corner is engaged (Lawrence
/// 2026-10-09: "hover on top left tabbar area when sidebar is closed needs
/// to bring the buttons visible. (animated width visible)").
///
/// The one input is the title bar row's `HoverReveal` state: the pointer
/// over its region, keyboard focus on a band button, or a hold. Engaged
/// with the sidebar hidden, the band opens at once; a band that is open
/// stays open while engaged (a click on the toggle that hides the sidebar
/// leaves the band under the pointer). Disengaged, it closes after
/// `closeDelay` (a `MainDeadline` on the app's scheduler), so a pointer that grazes the edge
/// does not flicker; a return before then cancels the close. While open
/// it holds the row's reveal, so the buttons stay shown for the whole
/// delay instead of fading before the band closes; that hold does not
/// count as engagement.
///
/// With `motion.renderServer` on (chrome-parity R2), a change sets the open
/// share once and lays the top row out once, at rest: the band, the badge
/// after it and the strips' tabs under it take their final frames in the
/// change's turn. The render server then shows them moving there with
/// additive springs from the frames they left (``RenderSpring``): the band
/// clips to its springing width and fades, its items keep their full size
/// inside it (``CollapsingBand``), and each strip's tab row springs with its
/// scrolling layer and edge fade. No frame of the motion runs main-thread
/// layout, and a change mid-flight adds its springs to the ones still
/// running, so what shows stays continuous. Chrome commits the layout and
/// lets the compositor animate the layers (cc/animation/keyframe_model.h;
/// ui/compositor/layer_animator.cc). With it off, the share is the width of
/// a constraint stepped per frame (`CollapsedBandReveal+CPUStep`). Reduce
/// Motion (or speed off) snaps the movement and crossfades.
@MainActor
public final class CollapsedBandReveal {
    /// How long the band stays open after the pointer leaves.
    public static let closeDelay: Duration = .milliseconds(300)

    /// Whether the row's reveal inputs count as engaged (pointer, focus or
    /// a hold other than this band's own; `isEnabled` is a display setting,
    /// not an engagement).
    public func isEngaged(_ state: HoverRevealState) -> Bool {
        state.pointerInside || state.focusInside || state.holds - (ownHold == nil ? 0 : 1) > 0
    }

    /// The row's reveal (its buttons' alpha): held while the band is open.
    public weak var reveal: HoverReveal?
    private var ownHold: HoverReveal.Hold?

    public private(set) var sidebarHidden = false
    public private(set) var engaged = false
    /// The band is open (or opening) over the hidden sidebar.
    public private(set) var isOpen = false
    /// Whether the last open or close moved (false under Reduce Motion,
    /// speed off, or a window with no screen).
    public private(set) var lastChangeAnimated = false
    /// The open share the window root lays out: 0 closed, 1 open, in between
    /// only while a stepped change animates ``driver``.
    public var presence: CGFloat { stepped ? steppedPresence : restShare }
    /// The share a render-server change set: 1 or 0, never in between.
    private var restShare: CGFloat = 0
    /// The last change stepped ``driver`` (`motion.renderServer` off).
    var stepped = false
    /// A render-server change has not landed: the band keeps its items at full size and clips.
    public private(set) var inFlight = false
    /// `motion.renderServer`, read at each change.
    private let rendersOnServer: () -> Bool
    /// The band's full width (the toolbar band's).
    let fullWidth: () -> CGFloat
    /// The stepped share's carrier: its width; takes no clicks, draws nothing.
    let driver = ShareDriverView(frame: .zero)
    /// ``driver``'s width constraint.
    var driverWidth: NSLayoutConstraint?
    /// The band's share on screen now (the sidebar's or this reveal's), so a
    /// stepped open starts from it instead of from 0.
    public var shownPresence: () -> CGFloat = { 0 }
    /// The top row the share lays out (the window root).
    private weak var root: NSView?
    /// The views a change of the share moves in the root: the band, which
    /// clips to its springing bounds, and what the root places after it (the
    /// badge, the host pressure indicator).
    public var riders: () -> (band: (any CollapsingBand)?, followers: [NSView]) = { (nil, []) }
    /// The layers of the window's strips that the top row places (`TabStripView.windowControlsLayers`).
    public var stripLayers: () -> [CALayer] = { [] }
    /// Each render-server change's landing, once: true when the band is at
    /// rest, false when a newer change took over (``RenderSpring/Completion``).
    public var onLanding: (_ finished: Bool) -> Void = { _ in }
    /// The close delay's one-shot deadline: `visible` work, the band is on screen.
    private let closeTimer: MainDeadline

    /// - Parameter deadlines: The app's one main-thread deadline scheduler.
    /// - Parameter fullWidth: The open band's width.
    /// - Parameter rendersOnServer: `motion.renderServer` (chrome-parity R2; off until p03-rendering-022c).
    public init(deadlines: MainDeadlineScheduler, fullWidth: @escaping () -> CGFloat, rendersOnServer: @escaping () -> Bool) {
        closeTimer = MainDeadline(owner: "CollapsedBandReveal.close", workClass: .visible, scheduler: deadlines)
        self.fullWidth = fullWidth
        self.rendersOnServer = rendersOnServer
        driver.setAccessibilityElement(false)
    }

    /// Lays `root` out on every change of the share, and adds the stepped driver to it.
    public func install(in root: NSView) {
        self.root = root
        installDriver(in: root)
    }

    public func setEngaged(_ value: Bool) {
        guard engaged != value else { return }
        engaged = value
        reconcile()
    }

    /// On the render server, the sidebar's share never adds to a spring of
    /// this one: a close still on screen when the sidebar shows turns into an
    /// open from where it shows, and the share drops only once the sidebar
    /// hides again (its width holds the band then, so the drop moves nothing).
    public func setSidebarHidden(_ value: Bool) {
        guard sidebarHidden != value else { return }
        sidebarHidden = value
        if !stepped, rendersOnServer() {
            if !value, inFlight, restShare == 0 { setPresence(1, token: .appear) }
            if value, !engaged, !isOpen, restShare > 0 { setPresence(0, token: .disappear) }
        }
        reconcile()
    }

    private func reconcile() {
        if engaged {
            closeTimer.cancel()
            if sidebarHidden, !isOpen { open() }
        } else if isOpen {
            closeTimer.scheduleIfIdle(after: Self.closeDelay) { [weak self] in
                guard let self, !engaged, isOpen else { return }
                close()
            }
        }
    }

    private func open() {
        isOpen = true
        if ownHold == nil, let reveal {
            // An open always comes from engagement, so the callback inside hold() changes nothing.
            ownHold = reveal.hold()
        }
        if rendersOnServer() { setPresence(1, token: .appear) } else { step(to: 1) }
    }

    private func close() {
        isOpen = false
        releaseHold()
        if !rendersOnServer() { step(to: 0) } else if sidebarHidden { setPresence(0, token: .disappear) }
    }

    /// Sets the share, lays the top row out once at rest, and springs every
    /// rider from where it showed on `token`.
    private func setPresence(_ value: CGFloat, token: MotionSpring) {
        stepped = false
        restShare = value
        park(at: value)
        guard let root else { return }
        let (band, followers) = riders()
        let spring = Motion.sidebar.renderSpring(token)
        lastChangeAnimated = spring.animates(RenderSpringKey<CGSize>.boundsSize.path, in: root)
        let shows = lastChangeAnimated || spring.animates(RenderSpringKey<CGFloat>.opacity.path, in: root)
        let bandRest = band.flatMap { RenderSpring.LayerRest($0) }
        let rests = (followers.compactMap(\.layer) + stripLayers()).map { RenderSpring.LayerRest($0) }
        // A button cannot spring its width: while the change shows, the band's clip and fade reveal its items at full size.
        if shows { band?.keepsItemsFullSize = true }
        root.needsLayout = true // invalidate: the band's open share changed.
        // The change's one layout: the band and what follows it take their rest frames now.
        // sync-layout: the springs below start from the frames this layout leaves, so they need its result in this turn.
        root.layoutSubtreeIfNeeded()
        guard let band, let bandMoves = bandRest?.moves(), !bandMoves.isEmpty else {
            // The band did not move (the sidebar's width holds it), so nothing after it did either.
            if !inFlight { band?.keepsItemsFullSize = false }
            return
        }
        inFlight = shows
        band.clipsToBounds = shows
        spring.animateGroup(bandMoves + rests.flatMap { $0.moves() }, in: root) { [weak self] finished in self?.land(finished) }
    }

    /// A change's landing. Only the newest lands finished: the band is at
    /// rest, and its items close up and draw unclipped again (focus rings).
    private func land(_ finished: Bool) {
        if finished {
            inFlight = false
            let band = riders().band
            band?.clipsToBounds = false
            band?.keepsItemsFullSize = false
        }
        onLanding(finished)
    }

    private func releaseHold() {
        let hold = ownHold
        ownHold = nil
        hold?.release()
    }
}

/// A band ``CollapsedBandReveal`` springs on the render server: while a change
/// shows, its items keep their full-size layout and the band's clip and fade
/// reveal them; at rest they close up with its share again.
@MainActor
public protocol CollapsingBand: NSView {
    var keepsItemsFullSize: Bool { get set }
}
