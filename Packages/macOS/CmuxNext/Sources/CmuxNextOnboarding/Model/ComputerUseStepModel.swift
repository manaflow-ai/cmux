public import Foundation
public import Observation
import CmuxNextWakeups
import CmuxNextWindowRules

/// Computer Use setup: one window with a row per grant the helper app
/// needs. Allow opens that list in System Settings and docks a panel with
/// the helper app to drag in; when the grant lands the panel goes, the
/// window comes back to the front by itself and the next row becomes the
/// primary one. Nothing is asked twice. Once the person's Allow got the last
/// grant on, the window shows its done view and closes by itself.
///
/// The rules are Rust's (cmux-window-rules `onboarding_steps::computer_use`, op
/// `onboarding_steps_computer_use`, with their cases): each event goes there with the window's
/// state, and this applies the answer's effects in order (the comeback, turning Computer Use on,
/// the Settings pane, the restart, the done timer). This keeps the helper's stream and the timer.
@MainActor
@Observable
public final class ComputerUseStepModel {
    public private(set) var permissions: ComputerUsePermissions = .none
    /// The list the drag panel is helping with, while it shows.
    public private(set) var helping: ComputerUsePermissionPane?
    /// Allow found no Developer ID signed helper: computer use is
    /// unavailable in this build, and the window says so instead of
    /// offering an ad-hoc helper for a grant.
    public private(set) var unavailable = false
    /// How many times a grant landed while its drag panel showed, or the
    /// panel's back button closed it. The window comes back to the front on
    /// each one.
    public private(set) var comebacks = 0
    /// The grants the person pressed Allow on in this window (an entry that opens the window at a
    /// grant counts too): the done view and the screen capture note follow them, so a window
    /// opened with every grant already on keeps its plain ready line.
    public private(set) var allowedHere: Set<ComputerUsePermissionPane> = []
    @ObservationIgnored let source: (any ComputerUsePermissionSource)?
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    /// Called by ``stop()`` (the window closed or the step left): the view takes its drag panel down at once.
    @ObservationIgnored var onStop: (@MainActor () -> Void)?
    /// The done view's time is up: the window closes (OnboardingModel ends it as Done).
    @ObservationIgnored var onFinished: (@MainActor () -> Void)?
    /// The done view's close; ``stop()`` (a manual close) cancels it.
    @ObservationIgnored let closeTimer: DemandTimer
    /// The window's state as the Rust rules keep it between events.
    @ObservationIgnored private var state = State()
    /// What the window shows, from the last answer.
    private var view = View()

    /// How long the done view shows before the window closes by itself.
    static let doneDelay: Duration = .milliseconds(2400)

    /// `clock` times the done view's close (tests pass one that ends at once or never).
    init(source: (any ComputerUsePermissionSource)?, clock: any Clock<Duration> = ContinuousClock()) {
        self.source = source
        closeTimer = DemandTimer(owner: "onboarding.computer-use.done", clock: clock)
        // The back button with no panel showing changes nothing: it reads the first view.
        send(.dismissHelper)
    }

    /// One event through the rules: the new state, then the effects in the order Rust names them.
    @discardableResult
    private func send(_ event: Event) -> Bool {
        state.source = source != nil
        state.helper = source?.helperAppURL != nil
        guard let outcome = WindowRules().call("onboarding_steps_computer_use",
                                               Request(state: state, event: event), as: Outcome.self) else { return false }
        state = outcome.state
        // Only what changed is written, so an unchanged grants read redraws nothing.
        let grants = outcome.state.grants.permissions
        if permissions != grants { permissions = grants }
        let shown = outcome.state.helping.flatMap(ComputerUsePermissionPane.init(rawValue:))
        if helping != shown { helping = shown }
        if unavailable != outcome.state.unavailable { unavailable = outcome.state.unavailable }
        let allowed = Set(outcome.state.allowedHere.compactMap(ComputerUsePermissionPane.init(rawValue:)))
        if allowedHere != allowed { allowedHere = allowed }
        if view != outcome.view { view = outcome.view }
        if outcome.comeback { comebacks += 1 }
        if outcome.enable { source?.enable() }
        if let pane = outcome.openSettings.flatMap(ComputerUsePermissionPane.init(rawValue:)) { source?.openSettings(pane) }
        if outcome.restart { source?.restart() }
        switch outcome.timer {
        case "schedule":
            closeTimer.scheduleIfIdle(after: Self.doneDelay) { @MainActor [weak self] in self?.doneTimeIsUp() }
        case "cancel": closeTimer.cancel()
        default: break
        }
        return outcome.accepted
    }

    private nonisolated struct Request: Encodable, Sendable { var state: State, event: Event }

    /// Follows the helper's grants while the window shows.
    func start() {
        guard task == nil, let source else { return }
        let stream = source.permissions()
        task = Task { [weak self] in
            for await value in stream {
                // stop() cancels on the main actor, so a value already
                // buffered then is dropped here rather than applied late.
                guard let self, !Task.isCancelled else { return }
                apply(value)
            }
        }
    }

    private func apply(_ value: ComputerUsePermissions) {
        send(.grants(value))
    }

    private func doneTimeIsUp() {
        guard finished, task != nil else { return }
        onFinished?()
    }

    func stop() {
        task?.cancel()
        task = nil
        send(.stop)
        onStop?()
    }

    /// The first grant still missing, in row order: the row whose Allow is
    /// the window's one primary action. Nil when every grant is on, or when
    /// no Allow can help (the helper failed or speaks another protocol).
    public var nextPane: ComputerUsePermissionPane? { view.nextPane.flatMap(ComputerUsePermissionPane.init(rawValue:)) }

    /// Whether `pane`'s Allow is the filled primary button: the next missing
    /// row, unless its drag panel already shows (then it waits, gray).
    public func isPrimary(_ pane: ComputerUsePermissionPane) -> Bool { view.primary == pane.rawValue }

    /// Every grant is on: the window shows its done state.
    public var allGranted: Bool { view.allGranted }

    /// Every grant is on after the person allowed one in this window: the done view, which closes
    /// the window by itself after ``doneDelay``. A window opened already ready never shows it.
    public var finished: Bool { view.finished }

    /// Screen Recording turned on after the person allowed it here: macOS asks once more, the first
    /// time the helper captures (the alert about bypassing the private window picker), so the
    /// Screenshots row says to allow it. Nothing reports that answer, so the line stays while the
    /// window shows.
    public var confirmsCapture: Bool { view.confirmsCapture }

    /// A row's trailing control for the current grants: `hidden`, `done`, `allowPrimary` or `allow`.
    public func control(_ pane: ComputerUsePermissionPane) -> String { view.control(pane) }

    /// The footer's one line on why Allow cannot help, if it cannot: `helperFailed`,
    /// `helperVersionMismatch`, `unavailable` or `off`.
    public var note: String? { view.note }

    /// Allow: the pane in System Settings, with the drag panel docked to it.
    /// Without a Developer ID signed helper there is nothing a grant would
    /// help: no list opens, no panel shows, and the window says computer use
    /// is unavailable in this build.
    public func allow(_ pane: ComputerUsePermissionPane) {
        send(.allow(pane))
    }

    /// An entry that opens the window at one grant (the palette's Grant actions, Settings' Grant
    /// Access): that grant's Allow, as soon as the grants are known. Nothing happens when it is
    /// already on or no Allow can help (the helper failed or speaks another protocol).
    public func allowOnceKnown(_ pane: ComputerUsePermissionPane) {
        send(.allowOnceKnown(pane))
    }

    /// Return in the window: the primary row's Allow. False when no row is
    /// primary (all done, or nothing to allow).
    @discardableResult
    public func allowNext() -> Bool {
        send(.allowNext)
    }

    /// Restarts a helper that did not answer setup.
    public func restart() {
        send(.restart)
    }

    /// The panel's back button: the panel goes and the window comes back to
    /// the front, its row primary again.
    public func dismissHelper() {
        send(.dismissHelper)
    }

    /// The helper app was dropped somewhere: read the grants again, since
    /// a drop into the list is how the grant usually lands. macOS may quit the
    /// helper to apply the grant ("Quit & Reopen"), so the source restarts it
    /// once if it stops answering (``ComputerUsePermissionSource/recheckAfterGrant()``).
    public func helperDropped() {
        guard helping != nil else { return }
        source?.recheckAfterGrant()
    }

    public var helperAppURL: URL? { source?.helperAppURL }
}
