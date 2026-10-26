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
/// Main lays the window root out once per change, then the render server
/// moves the band: `presence` is the committed share the root lays out
/// with, and the band's visible width is a clip that springs on the
/// render server (`RenderClip`), so no frame of the motion lays out.
/// An open commits at once and the clip grows from what shows; a close
/// clips the band away and commits when it lands, so the band never
/// shrinks under its own clip. A change mid-flight retargets the additive
/// spring, so the shown width stays continuous. Reduce Motion (or speed
/// off, or no screen) commits at once with no clip.
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
    /// speed off, a window with no screen, or nothing left to show).
    private(set) var lastChangeAnimated = false
    /// The open share the root lays out with: 0 closed, 1 open. It changes
    /// once per open (at its start) and once per close (when its clip lands).
    private(set) var presence: CGFloat = 0 {
        didSet { if presence != oldValue { root?.needsLayout = true } }
    }
    /// The close delay's one-shot deadline.
    private let closeTimer: DemandTimer
    private let clip: any RenderClipMotion
    private weak var root: NSView?
    private weak var band: NSView?
    /// A clip is on the band (a spring runs or has not landed yet).
    private var clipping = false
    /// Bumped by every change, so only the latest clip's landing commits.
    private var change = 0
    /// The band's share on screen now (the sidebar's or this reveal's), so
    /// an open starts from it instead of from 0.
    var shownPresence: () -> CGFloat = { 0 }

    /// - Parameter clip: Where the band's clip springs (tests pass a recorder).
    init(clock: any Clock<Duration> = ContinuousClock(), clip: (any RenderClipMotion)? = nil) {
        closeTimer = DemandTimer(owner: "CollapsedBandReveal.close", clock: clock)
        self.clip = clip ?? RenderClip(gate: Motion.sidebar)
    }

    /// `root` lays out with ``presence``; `band` is the view the clip shows.
    func install(in root: NSView, band: NSView) {
        self.root = root
        self.band = band
    }

    func setEngaged(_ value: Bool) {
        guard engaged != value else { return }
        engaged = value
        reconcile()
    }

    func setSidebarHidden(_ value: Bool) {
        guard sidebarHidden != value else { return }
        sidebarHidden = value
        // A shown sidebar shows the whole band: a clip in flight opens back up from what it shows.
        if !value, clipping { reopenClip() }
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
        // Read before the commit: a sidebar still sliding out, so the band never dips.
        // A clip in flight continues from what it shows (the additive retarget).
        let start: CGFloat? = clipping ? nil : min(full, shownPresence() * full)
        change += 1
        presence = 1
        guard let band, clip.animates(in: band), start.map({ $0 < full }) ?? true else {
            lastChangeAnimated = false
            return land()
        }
        lastChangeAnimated = true
        run(on: band, from: start, to: full, token: .appear)
    }

    private func close() {
        isOpen = false
        releaseHold()
        change += 1
        // With the sidebar shown, its own width shows the band: nothing to clip.
        guard sidebarHidden, presence > 0, let band, clip.animates(in: band) else {
            lastChangeAnimated = false
            return land()
        }
        lastChangeAnimated = true
        run(on: band, from: clipping ? nil : TitlebarToolbarBand.width, to: 0, token: .disappear)
    }

    private func reopenClip() {
        change += 1
        guard let band, clip.animates(in: band) else { return land() }
        run(on: band, from: nil, to: TitlebarToolbarBand.width, token: .appear)
    }

    private func run(on band: NSView, from start: CGFloat?, to width: CGFloat, token: MotionSpring) {
        clipping = true
        let landing = change
        clip.clip(band, from: start, to: width, token: token) { [weak self] in
            guard let self, landing == change else { return }
            land()
        }
    }

    /// Commits the model and removes the clip: one layout when the share changed.
    private func land() {
        presence = isOpen ? 1 : 0
        guard clipping else { return }
        clipping = false
        if let band { clip.unclip(band) }
    }

    private func releaseHold() {
        let hold = ownHold
        ownHold = nil
        hold?.release()
    }
}
