import AppKit
import CmuxNextDesign
import CmuxNextWakeups

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
/// A change sets the open share once and lays the top row out once, at
/// rest: the band, the badge after it and the strips' tabs under it take
/// their final frames in the change's turn. The render server then shows
/// them moving there with additive springs from the frames they left
/// (``RenderSpring``), the band clipped to its springing width, so no frame
/// of the motion runs main-thread layout. A change mid-flight adds its
/// springs to the ones still running, so what shows stays continuous.
/// Chrome commits the layout and lets the compositor animate the layers
/// (cc/animation/keyframe_model.h; ui/compositor/layer_animator.cc).
/// Reduce Motion (or speed off) snaps the movement and crossfades.
@MainActor
final class CollapsedBandReveal {
    /// How long the band stays open after the pointer leaves.
    static let closeDelay: Duration = .milliseconds(300)

    /// Whether the row's reveal inputs count as engaged (pointer, focus or
    /// a hold other than this band's own; `isEnabled` is a display setting,
    /// not an engagement).
    func isEngaged(_ state: HoverRevealState) -> Bool {
        state.pointerInside || state.focusInside || state.holds - (ownHold == nil ? 0 : 1) > 0
    }

    /// The row's reveal (its buttons' alpha): held while the band is open.
    weak var reveal: HoverReveal?
    private var ownHold: HoverReveal.Hold?

    private(set) var sidebarHidden = false
    private(set) var engaged = false
    /// The band is open (or opening) over the hidden sidebar.
    private(set) var isOpen = false
    /// Whether the last open or close moved on the render server (false under
    /// Reduce Motion, speed off, or a window with no screen).
    private(set) var lastChangeAnimated = false
    /// The open share at rest: 1 open, 0 closed. It changes once per open or
    /// close, never per frame; the window root's layout reads it.
    private(set) var presence: CGFloat = 0
    /// The top row the share lays out (the window root).
    private weak var root: NSView?
    /// The views a change of the share moves in the root: the band, which
    /// clips to its springing bounds, and what the root places after it (the
    /// badge, the host pressure indicator).
    var riders: () -> (band: NSView?, followers: [NSView]) = { (nil, []) }
    /// The tab rows of the window's strips (`TabStripView.windowControlsRows`):
    /// those under the top row move with the band.
    var stripRows: () -> [NSView] = { [] }
    /// The close delay's one-shot deadline: `visible` work, the band is on screen.
    private let closeTimer: MainDeadline

    /// - Parameter deadlines: The app's one main-thread deadline scheduler.
    init(deadlines: MainDeadlineScheduler) {
        closeTimer = MainDeadline(owner: "CollapsedBandReveal.close", workClass: .visible, scheduler: deadlines)
    }

    /// Lays `root` out on every change of the share.
    func install(in root: NSView) {
        self.root = root
    }

    func setEngaged(_ value: Bool) {
        guard engaged != value else { return }
        engaged = value
        reconcile()
    }

    func setSidebarHidden(_ value: Bool) {
        guard sidebarHidden != value else { return }
        sidebarHidden = value
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
        setPresence(1, token: .appear)
    }

    private func close() {
        isOpen = false
        releaseHold()
        setPresence(0, token: .disappear)
    }

    /// Sets the share, lays the top row out once at rest, and springs every
    /// rider from where it showed on `token`.
    private func setPresence(_ value: CGFloat, token: MotionSpring) {
        presence = value
        guard let root else { return }
        let (band, followers) = riders()
        let bandRest = band.flatMap { RenderSpring.LayerRest($0) }
        let followerRests = (followers + stripRows()).map { view in (view, RenderSpring.LayerRest(view)) }
        root.needsLayout = true // invalidate: the band's open share changed.
        // The change's one layout: the band and what follows it take their rest frames now.
        // sync-layout: the springs below start from the frames this layout leaves, so they need its result in this turn.
        root.layoutSubtreeIfNeeded()
        let spring = Motion.sidebar.renderSpring(token)
        lastChangeAnimated = spring.animates(RenderSpringKey<CGSize>.boundsSize.path, in: root)
        guard let band, let bandMoves = bandRest?.moves(to: band), !bandMoves.isEmpty else {
            // The band did not move (the sidebar's width holds it open), so nothing after it did either.
            return
        }
        var moves = bandMoves
        for (view, rest) in followerRests { moves += rest?.moves(to: view) ?? [] }
        if lastChangeAnimated { band.clipsToBounds = true }
        // The newest change's landing is the band at rest: its items draw unclipped again (focus rings).
        spring.animateGroup(moves, in: root) { [weak band] finished in
            if finished { band?.clipsToBounds = false }
        }
    }

    private func releaseHold() {
        let hold = ownHold
        ownHold = nil
        hold?.release()
    }
}
