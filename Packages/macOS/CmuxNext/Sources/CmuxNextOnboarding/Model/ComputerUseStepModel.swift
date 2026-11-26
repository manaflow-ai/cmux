public import Foundation
public import Observation
import CmuxNextWakeups

/// Computer Use setup: one window with a row per grant the helper app
/// needs. Allow opens that list in System Settings and docks a panel with
/// the helper app to drag in; when the grant lands the panel goes, the
/// window comes back to the front by itself and the next row becomes the
/// primary one. Nothing is asked twice. Once the person's Allow got the last
/// grant on, the window shows its done view and closes by itself.
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
    /// A grant an entry asked for (`allowOnceKnown`) before the first grants read came in.
    @ObservationIgnored private var pendingAllow: ComputerUsePermissionPane?
    @ObservationIgnored private var received = false

    /// How long the done view shows before the window closes by itself.
    static let doneDelay: Duration = .milliseconds(2400)

    /// `clock` times the done view's close (tests pass one that ends at once or never).
    init(source: (any ComputerUsePermissionSource)?, clock: any Clock<Duration> = ContinuousClock()) {
        self.source = source
        closeTimer = DemandTimer(owner: "onboarding.computer-use.done", clock: clock)
    }

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
        permissions = value
        received = true
        if value.helperFailed { helping = nil }
        if let pane = helping, value.granted(pane) {
            helping = nil
            comebacks += 1
        }
        // An entry's Allow waits until the helper answered: grants still being read look missing.
        if let pane = pendingAllow, !value.isReading {
            pendingAllow = nil
            if nextPane != nil { allow(pane) }
        }
        if finished {
            closeTimer.scheduleIfIdle(after: Self.doneDelay) { @MainActor [weak self] in self?.doneTimeIsUp() }
        } else {
            closeTimer.cancel()
        }
    }

    private func doneTimeIsUp() {
        guard finished, task != nil else { return }
        onFinished?()
    }

    func stop() {
        task?.cancel()
        task = nil
        helping = nil
        pendingAllow = nil
        closeTimer.cancel()
        onStop?()
    }

    /// The first grant still missing, in row order: the row whose Allow is
    /// the window's one primary action. Nil when every grant is on, or when
    /// no Allow can help (the helper failed or speaks another protocol).
    public var nextPane: ComputerUsePermissionPane? {
        guard !permissions.helperFailed, !permissions.helperVersionMismatch else { return nil }
        return ComputerUsePermissionPane.allCases.first { !permissions.granted($0) }
    }

    /// Whether `pane`'s Allow is the filled primary button: the next missing
    /// row, unless its drag panel already shows (then it waits, gray).
    public func isPrimary(_ pane: ComputerUsePermissionPane) -> Bool {
        pane == nextPane && helping != pane && !unavailable
    }

    /// Every grant is on: the window shows its done state.
    public var allGranted: Bool {
        !permissions.isOff && !permissions.helperFailed && !permissions.helperVersionMismatch
            && ComputerUsePermissionPane.allCases.allSatisfy { permissions.granted($0) }
    }

    /// Every grant is on after the person allowed one in this window: the done view, which closes
    /// the window by itself after ``doneDelay``. A window opened already ready never shows it.
    public var finished: Bool { allGranted && !allowedHere.isEmpty }

    /// Screen Recording turned on after the person allowed it here: macOS asks once more, the first
    /// time the helper captures (the alert about bypassing the private window picker), so the
    /// Screenshots row says to allow it. Nothing reports that answer, so the line stays while the
    /// window shows.
    public var confirmsCapture: Bool {
        allowedHere.contains(.screenRecording) && permissions.screenRecording
            && !permissions.helperFailed && !permissions.helperVersionMismatch
    }

    /// Allow: the pane in System Settings, with the drag panel docked to it.
    /// Without a Developer ID signed helper there is nothing a grant would
    /// help: no list opens, no panel shows, and the window says computer use
    /// is unavailable in this build.
    public func allow(_ pane: ComputerUsePermissionPane) {
        guard let source, !permissions.granted(pane) else { return }
        guard source.helperAppURL != nil else {
            unavailable = true
            helping = nil
            return
        }
        unavailable = false
        // Computer Use is off: the person's Allow turns it on, so the helper
        // that needs the grant starts and its rows turn Done by themselves.
        if permissions.isOff { source.enable() }
        source.openSettings(pane)
        allowedHere.insert(pane)
        helping = pane
    }

    /// An entry that opens the window at one grant (the palette's Grant actions, Settings' Grant
    /// Access): that grant's Allow, as soon as the grants are known. Nothing happens when it is
    /// already on or no Allow can help (the helper failed or speaks another protocol).
    public func allowOnceKnown(_ pane: ComputerUsePermissionPane) {
        guard received, !permissions.isReading else {
            pendingAllow = pane
            return
        }
        guard nextPane != nil, helping != pane else { return }
        allow(pane)
    }

    /// Return in the window: the primary row's Allow. False when no row is
    /// primary (all done, or nothing to allow).
    @discardableResult
    public func allowNext() -> Bool {
        guard let pane = nextPane, isPrimary(pane) else { return false }
        allow(pane)
        return true
    }

    /// Restarts a helper that did not answer setup.
    public func restart() {
        guard permissions.helperFailed else { return }
        unavailable = false
        helping = nil
        source?.restart()
    }

    /// The panel's back button: the panel goes and the window comes back to
    /// the front, its row primary again.
    public func dismissHelper() {
        guard helping != nil else { return }
        helping = nil
        comebacks += 1
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
