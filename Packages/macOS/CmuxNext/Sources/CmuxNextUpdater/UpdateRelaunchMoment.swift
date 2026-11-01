import AppKit
import CmuxNextWakeups

/// What an automatic install's relaunch would cut off right now. The install never waits for
/// anything else (Leo, 2026-10-26: "if the nightly is post, I just want it. Just give it to me.
/// Don't wait. Like, stop waiting."): only the moment a modal, a sheet, an open menu or an input
/// method's composition is up, and it starts within a second of none being up.
public struct UpdateRelaunchMoment: Equatable, Sendable {
    /// A modal session runs (`NSApp.modalWindow`: an alert, an open or save panel run modally).
    public var modal = false
    /// A window has a sheet attached.
    public var sheet = false
    /// A menu (or another tracking loop: a context menu, a drag) is tracking the pointer.
    public var tracking = false
    /// A window's first responder holds marked text: an input method is composing. Covers AppKit
    /// text views and both web engines, whose typing views are `NSTextInputClient`s: `WKWebView`,
    /// and Chromium's `RenderWidgetHostViewCocoa` in the page's `CefNSWindow`, a child window
    /// that takes key so the page gets the keyboard (`ChromiumPageWindowMain`).
    public var composing = false

    public init(modal: Bool = false, sheet: Bool = false, tracking: Bool = false, composing: Bool = false) {
        self.modal = modal
        self.sheet = sheet
        self.tracking = tracking
        self.composing = composing
    }

    /// Why a relaunch now would cut something off, or nil when it would not.
    public var interruption: String? {
        if modal { return "a modal is up" }
        if sheet { return "a sheet is up" }
        if tracking { return "a menu is open" }
        if composing { return "text is mid-composition" }
        return nil
    }

    /// The app's moment now (main thread).
    @MainActor public static func current() -> UpdateRelaunchMoment {
        let app = NSApplication.shared
        let windows = app.windows
        return UpdateRelaunchMoment(
            modal: app.modalWindow != nil,
            sheet: windows.contains { $0.attachedSheet != nil },
            tracking: RunLoop.main.currentMode == .eventTracking,
            composing: windows.contains { ($0.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true })
    }
}

/// Holds one automatic install until the app's ``UpdateRelaunchMoment`` clears, then runs it once.
///
/// While held it re-reads the moment once a second on one ``DemandTimer``, and on ``recheck()``.
/// It observes no event: the one that announces every end (`NSApplication.didUpdateNotification`)
/// posts after each event-loop pass, so following it cost a main-actor Task per pass while an
/// update waited. Stop condition: the moment clears (the install runs), a newer hold replaces it,
/// or ``cancel()``. Each of them cancels the timer; nothing runs while nothing is held.
@MainActor
final class UpdateRelaunchMomentHold {
    /// The longest a moment that cleared goes unnoticed.
    static let recheckInterval: Duration = .seconds(1)

    private let moment: @MainActor () -> UpdateRelaunchMoment
    private let timer: DemandTimer
    private let log: (String) -> Void
    private var ready: (@MainActor () -> Void)?
    /// Ends a ``waitUntilClear()`` whose hold is dropped instead of released.
    private var dropped: (() -> Void)?

    init(moment: @escaping @MainActor () -> UpdateRelaunchMoment = { .current() },
         clock: any Clock<Duration> = ContinuousClock(),
         log: @escaping (String) -> Void = { _ in }) {
        self.moment = moment
        self.log = log
        timer = DemandTimer(owner: "UpdaterService.relaunchMoment", clock: clock)
    }

    /// Whether an install waits.
    var isHolding: Bool { ready != nil }

    /// False when nothing would be cut off (the caller installs now). Otherwise keeps `ready`,
    /// replacing an earlier hold, and runs it once the moment clears.
    func hold(_ ready: @escaping @MainActor () -> Void) -> Bool {
        cancel()
        guard let reason = moment().interruption else { return false }
        log("automatic install waits: \(reason)")
        self.ready = ready
        scheduleRecheck()
        return true
    }

    /// Runs the held install if the moment has cleared.
    func recheck() {
        guard let ready else { return }
        guard moment().interruption == nil else { return }
        log("automatic install: nothing would be cut off now; installing")
        dropped = nil
        cancel()
        ready()
    }

    /// Returns at once when nothing would be cut off, else once the moment clears (true) or the
    /// hold is dropped (false: a click, a cancel or a newer hold took over). A true answer is
    /// checked again when the caller resumes, so nothing that began in between is missed: the
    /// caller acts in the same main-actor turn as that last check.
    func waitUntilClear() async -> Bool {
        // Each wait suspends on a hold (released only by the 1 s timer or a recheck), never spins.
        let cleared = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let held = hold { done.resume(returning: true) }
            if held { dropped = { done.resume(returning: false) } } else { done.resume(returning: true) }
        }
        guard cleared else { return false }
        if moment().interruption == nil { return true }
        return await waitUntilClear()
    }

    /// Drops the held install without running it.
    func cancel() {
        let drop = dropped
        dropped = nil
        ready = nil
        timer.cancel()
        drop?()
    }

    private func scheduleRecheck() {
        timer.schedule(after: Self.recheckInterval) { @MainActor [weak self] in
            guard let self, self.isHolding else { return }
            self.recheck()
            if self.isHolding { self.scheduleRecheck() }
        }
    }
}
