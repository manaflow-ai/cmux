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
/// `closeDelay` on the injected clock, so a pointer that grazes the edge
/// does not flicker; a return before then cancels the close. While open
/// it holds the row's reveal, so the buttons stay shown for the whole
/// delay instead of fading before the band closes; that hold does not
/// count as engagement.
///
/// The open share is the width of `driver`, a constraint animated with the
/// sidebar's tokens: every animation frame lays the window root out, which
/// places the band and the strips under it in the same pass, the same way
/// the sidebar's own width drives the band. A change mid-animation
/// retargets from what is on screen. Reduce Motion (or speed off) snaps.
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
    /// Whether the last open or close animated (false under Reduce Motion,
    /// speed off, or a window with no screen).
    private(set) var lastChangeAnimated = false
    /// Carries the open share as its width; takes no clicks, draws nothing.
    let driver = PassThroughView(frame: .zero)
    private var width: NSLayoutConstraint?
    /// The close delay's one-shot deadline.
    private let closeTimer: DemandTimer
    /// The band's share on screen now (the sidebar's or this driver's), so
    /// an open starts from it instead of from 0.
    var shownPresence: () -> CGFloat = { 0 }

    init(clock: any Clock<Duration> = ContinuousClock()) {
        closeTimer = DemandTimer(owner: "CollapsedBandReveal.close", clock: clock)
        driver.setAccessibilityElement(false)
    }

    /// Adds the driver to `root` (top-leading, 0 tall).
    func install(in root: NSView) {
        driver.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(driver)
        let width = driver.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            driver.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            driver.topAnchor.constraint(equalTo: root.topAnchor),
            driver.heightAnchor.constraint(equalToConstant: 0),
            width,
        ])
        self.width = width
    }

    /// The open share on screen: 0 closed, 1 open, in between while it animates.
    var presence: CGFloat {
        min(1, max(0, driver.frame.width / TitlebarToolbarBand.width))
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
            closeTimer.scheduleIfIdle(after: Self.closeDelay) { @MainActor [weak self] in
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
        let full = TitlebarToolbarBand.width
        guard let width else { return }
        lastChangeAnimated = animates
        guard lastChangeAnimated else { width.constant = full; return }
        // Start from what shows (a sidebar that is still sliding out), so the band never dips.
        let start = max(presence, shownPresence()) * full
        if start > width.constant {
            Motion.withoutAnimation { Motion.animator(width, in: driver).constant = start }
        }
        Motion.animateTimed(.appear, in: driver) { Motion.animator(width, in: driver).constant = full }
    }

    private func close() {
        isOpen = false
        releaseHold()
        guard let width else { return }
        lastChangeAnimated = animates
        guard lastChangeAnimated else { width.constant = 0; return }
        Motion.animateExit(.disappear, in: driver) { Motion.animator(width, in: driver).constant = 0 }
    }

    private func releaseHold() {
        let hold = ownHold
        ownHold = nil
        hold?.release()
    }

    private var animates: Bool { Motion.policy.animatesMovement && Motion.canAnimate(in: driver) }
}
