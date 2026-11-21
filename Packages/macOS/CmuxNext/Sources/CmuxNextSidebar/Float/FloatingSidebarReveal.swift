public import AppKit
import CmuxNextWakeups

/// Floats the hidden sidebar over the content while the pointer is at the window's sidebar edge
/// (`sidebar.floatOnHover`, on by default; Lawrence 2026-11-08: "if sidebar is closed, we should
/// have a toggleable mode, that will show a floating version of sidebar if mouse moves to left").
///
/// Two pointer inputs: the edge zone (a thin strip on the window's sidebar edge, below the top
/// row) and the floating panel's zone. The pointer resting in the edge zone for ``openDelay``
/// opens the float, so a pointer that only passes the edge opens nothing. Open, it stays while the
/// pointer is in either zone; once it leaves both, it closes after ``closeDelay``, so a short
/// overshoot does not drop it. A hold (``holdsOpen``: a menu, a drag, an inline rename or search
/// in the sidebar) keeps it open past that delay; whoever ends the hold calls ``reconcile()``,
/// and the delay starts again. A click outside the panel closes it at once (``close()``).
///
/// It floats only while the sidebar is hidden, the setting is on (``isEnabled``) and the window
/// allows it (``isAllowed``: not over Home, which has its own list on that edge, nor a page with
/// the whole window). Showing the sidebar (Toggle Sidebar from any entry point) ends the float
/// where it is: ``SidebarModel/toggle()`` and the model's presentation own that, not this type.
/// Both deadlines run on the injected clock.
///
/// Only an entry opens it (Lawrence 2026-11-11, msg 29542: "when hiding sidebar, and my mouse is near
/// left side of screen, it kinda hides and reappears. we need to eliminate that error class
/// completely"). The edge zone appears whenever floating becomes possible (the sidebar hidden, Home
/// left, the setting turned on); a pointer already on the edge then reads "inside" at once, which is
/// not intent. Each such start disarms the edge (``edgeArmed``); it arms once the pointer is seen off
/// the edge with the zone in place (``isEdgePlaced``) and the hide's slide over (``isSettling``), or
/// when the pointer enters a zone that was already in place at the last reconcile after the slide
/// (the first move onto the edge after a hide: nothing reconciles when the slide lands). A zone that
/// appears under the pointer reads it in the layout pass that places it, before that pass reconciles,
/// so it is no entry: a pointer resting through the hide, or reaching the edge during its slide, must
/// leave and come back to float the sidebar.
@MainActor
public final class FloatingSidebarReveal {
    /// How long the pointer rests on the edge before the sidebar floats in (intent, not a pass).
    /// 100 ms: long enough that a pointer crossing the edge on its way elsewhere opens nothing,
    /// short enough to read as a response (Lawrence 2026-11-11: "better spring animation and
    /// shorter duration").
    public static let openDelay: Duration = .milliseconds(100)
    /// How long the float stays after the pointer left it.
    public static let closeDelay: Duration = .milliseconds(350)
    /// The edge zone's width, in points from the window's sidebar edge.
    public static let edgeWidth: CGFloat = 6

    /// The window's sidebar model: the float is its ``SidebarModel/isFloating``.
    public let model: SidebarModel
    /// `sidebar.floatOnHover`.
    public var isEnabled: @MainActor () -> Bool = { true }
    /// Whether this window may float its sidebar now (not over Home or a page with the whole window).
    public var isAllowed: @MainActor () -> Bool = { true }
    /// Whether something in the sidebar must keep the float open (a menu, a drag, an edit).
    public var holdsOpen: @MainActor () -> Bool = { false }
    /// The pointer's place now, read when the close deadline fires: a zone's exit can be lost
    /// while a menu tracks.
    public var pointerInPanel: @MainActor () -> Bool = { false }

    /// Whether the sidebar's hide slide still runs (the window passes its container's on-screen share):
    /// the edge does not arm until it lands.
    public var isSettling: @MainActor () -> Bool = { false }
    /// Whether the edge zone is in place (its probe has read the pointer), so "not engaged" is a fact
    /// and not a zone still at `.zero`.
    public var isEdgePlaced: @MainActor () -> Bool = { true }
    /// Whether an edge engagement may open the float: false from the moment floating becomes
    /// possible until the pointer is seen off the edge.
    public private(set) var edgeArmed = true
    /// ``canFloat`` at the last reconcile, to see floating become possible.
    private var couldFloat: Bool
    /// ``isEdgePlaced`` at the last reconcile: an entry into a zone placed after it is the zone
    /// appearing under the pointer, not a move onto the edge.
    private var edgeWasPlaced = false

    /// The pointer is in the edge zone.
    public private(set) var edgeEngaged = false
    /// The pointer is over the floating sidebar's zone.
    public private(set) var panelEngaged = false
    private let openTimer: DemandTimer
    private let closeTimer: DemandTimer

    /// - Parameter model: The window's sidebar model.
    /// - Parameter clock: Times the open and close delays (tests pass a manual clock).
    public init(model: SidebarModel, clock: any Clock<Duration> = ContinuousClock()) {
        self.model = model
        couldFloat = model.isHidden
        openTimer = DemandTimer(owner: "FloatingSidebarReveal.open", clock: clock)
        closeTimer = DemandTimer(owner: "FloatingSidebarReveal.close", clock: clock)
    }

    /// The sidebar floats now.
    public var isOpen: Bool { model.isFloating }

    /// Every condition but the pointer.
    public var canFloat: Bool { model.isHidden && isEnabled() && isAllowed() }

    /// The pointer entered or left the edge zone.
    public func setEdgeEngaged(_ value: Bool) {
        guard edgeEngaged != value else { return }
        edgeEngaged = value
        // A move onto a zone that was in place and floatable at the last reconcile, after the hide's slide.
        if value, !edgeArmed, couldFloat, edgeWasPlaced, !isSettling() { edgeArmed = true }
        reconcile()
    }

    /// The pointer entered or left the floating sidebar's zone.
    public func setPanelEngaged(_ value: Bool) {
        guard panelEngaged != value else { return }
        panelEngaged = value
        reconcile()
    }

    /// Applies the inputs: schedules or cancels the open and the close. Also the call after a
    /// hold ended, a setting changed or the window's content changed.
    public func reconcile() {
        let floatable = canFloat
        if floatable != couldFloat {
            couldFloat = floatable
            if floatable, !isOpen { edgeArmed = false }
        }
        let placed = isEdgePlaced()
        if floatable, !edgeArmed, !edgeEngaged, placed, !isSettling() { edgeArmed = true }
        edgeWasPlaced = placed
        guard isOpen else {
            closeTimer.cancel()
            guard edgeEngaged, edgeArmed, floatable else { return openTimer.cancel() }
            openTimer.scheduleIfIdle(after: Self.openDelay) { @MainActor [weak self] in self?.openIfStillWanted() }
            return
        }
        openTimer.cancel()
        guard canFloat else { return close() }
        if edgeEngaged || panelEngaged {
            closeTimer.cancel()
        } else {
            closeTimer.scheduleIfIdle(after: Self.closeDelay) { @MainActor [weak self] in self?.closeIfStillUnwanted() }
        }
    }

    /// Ends the float now (a click outside it, the setting off, Home shown).
    public func close() {
        openTimer.cancel()
        closeTimer.cancel()
        if model.isFloating { model.isFloating = false }
    }

    private func openIfStillWanted() {
        guard !isOpen, edgeEngaged, edgeArmed, canFloat else { return }
        model.isFloating = true
        reconcile()
    }

    private func closeIfStillUnwanted() {
        guard isOpen, !edgeEngaged, !panelEngaged else { return }
        // A hold's end calls reconcile(), which starts the delay again.
        guard !holdsOpen() else { return }
        if pointerInPanel() { return setPanelEngaged(true) }
        close()
    }
}
