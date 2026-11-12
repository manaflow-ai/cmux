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
@MainActor
public final class FloatingSidebarReveal {
    /// How long the pointer rests on the edge before the sidebar floats in (intent, not a pass).
    public static let openDelay: Duration = .milliseconds(150)
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
        guard isOpen else {
            closeTimer.cancel()
            guard edgeEngaged, canFloat else { return openTimer.cancel() }
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
        guard !isOpen, edgeEngaged, canFloat else { return }
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
