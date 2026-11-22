import AppKit
public import CmuxNextSettings
import CmuxNextWakeups
public import Foundation
import Observation

/// What an automatic install's relaunch would cut off right now. The install never waits for
/// anything else (Leo, 2026-10-26: "if the nightly is post, I just want it. Just give it to me.
/// Don't wait. Like, stop waiting."): only the moment a modal, a sheet, an open menu or an input
/// method's composition is up where the person can see it, and it starts within a second of none
/// being up. A window that is not on screen or in the Dock (a parked spare, a hidden page window)
/// holds nothing: nobody is looking at it, so a relaunch cuts nothing off there.
nonisolated public struct UpdateRelaunchMoment: Equatable, Sendable {
    /// Why a relaunch now would cut something off (``UpdateRelaunchHoldState/reason``).
    nonisolated public enum Interruption: String, Equatable, Sendable, CustomStringConvertible {
        case modal, sheet, menu, composing
        /// Update When Idle (`updates.installWhenIdle`, ``UpdateRelaunchMomentHold/idleGate``): input came
        /// within the idle time, a composer holds an unsent message, or one of those could not be
        /// read. A running agent turn does not hold it: the turn carries across the relaunch.
        case notIdle, unsentDraft, unknown
        /// Update When Idle: the last automatic install was declined (the app did not quit), so the next
        /// try waits out a backoff (cmux-window-rules `update_idle::retry_after_seconds`).
        case backoff

        /// The log's words.
        public var description: String {
            switch self {
            case .modal: "a modal is up"
            case .sheet: "a sheet is up"
            case .menu: "a menu is open"
            case .composing: "text is mid-composition"
            case .notIdle: "input came within the idle time"
            case .unsentDraft: "a composer holds an unsent message"
            case .unknown: "the agents' state is unknown"
            case .backoff: "the last automatic install was declined; backing off"
            }
        }

        /// Update When Idle's answer (cmux-window-rules `update_idle`'s hold reason; nil installs): a reason this
        /// build does not know, `off` included, holds as unknown.
        public static func idleHold(_ reason: String?) -> Self? {
            reason.map { Self(rawValue: $0).flatMap { [.notIdle, .unsentDraft, .backoff].contains($0) ? $0 : nil } ?? .unknown }
        }
    }

    /// One window as the moment reads it.
    nonisolated public struct Window: Equatable, Sendable {
        /// On screen, in the Dock (miniaturized) or key: the person can see it or bring it back.
        public var isShown: Bool
        public var hasSheet: Bool
        /// Its first responder holds marked text (an input method is composing).
        public var hasMarkedText: Bool

        public init(isShown: Bool, hasSheet: Bool = false, hasMarkedText: Bool = false) {
            self.isShown = isShown
            self.hasSheet = hasSheet
            self.hasMarkedText = hasMarkedText
        }

        /// Reads `window`; a window that is not shown reads nothing else (it holds nothing).
        @MainActor init(_ window: NSWindow) {
            isShown = window.isVisible || window.isMiniaturized || window.isKeyWindow
            hasSheet = isShown && window.attachedSheet != nil
            hasMarkedText = isShown && (window.firstResponder as? any NSTextInputClient)?.hasMarkedText() == true
        }
    }

    /// A modal session runs (`NSApp.modalWindow`: an alert, an open or save panel run modally).
    public var modal = false
    /// A shown window has a sheet attached.
    public var sheet = false
    /// A menu (or another tracking loop: a context menu, a drag) is tracking the pointer.
    public var tracking = false
    /// A shown window's first responder holds marked text: an input method is composing. Covers
    /// AppKit text views and both web engines, whose typing views are `NSTextInputClient`s:
    /// `WKWebView`, and Chromium's `RenderWidgetHostViewCocoa` in the page's `CefNSWindow`, a child
    /// window that takes key so the page gets the keyboard (`ChromiumPageWindowMain`).
    public var composing = false

    public init(modal: Bool = false, sheet: Bool = false, tracking: Bool = false, composing: Bool = false) {
        self.modal = modal
        self.sheet = sheet
        self.tracking = tracking
        self.composing = composing
    }

    /// The moment of `windows`: only shown windows' sheets and compositions count.
    public init(modal: Bool, tracking: Bool, windows: [Window]) {
        let shown = windows.lazy.filter(\.isShown)
        self.init(modal: modal, sheet: shown.contains { $0.hasSheet }, tracking: tracking,
                  composing: shown.contains { $0.hasMarkedText })
    }

    /// Why a relaunch now would cut something off, or nil when it would not.
    public var interruption: Interruption? {
        if modal { return .modal }
        if sheet { return .sheet }
        if tracking { return .menu }
        if composing { return .composing }
        return nil
    }

    /// The app's moment now (main thread).
    @MainActor public static func current() -> UpdateRelaunchMoment {
        let app = NSApplication.shared
        return UpdateRelaunchMoment(modal: app.modalWindow != nil,
                                    tracking: RunLoop.main.currentMode == .eventTracking,
                                    windows: app.windows.map(Window.init))
    }
}

/// The automatic install ``UpdateRelaunchMomentHold`` holds: why, since when, and whether it has
/// waited past its bound. Read by the staged update card (its popover says why it waits), the
/// Settings Updates card and the control socket's updater status.
nonisolated public struct UpdateRelaunchHoldState: Equatable, Sendable {
    /// What the relaunch would cut off now (updated on every recheck).
    public var reason: UpdateRelaunchMoment.Interruption
    /// When the hold began.
    public var since: Date
    /// The hold outlived ``UpdateRelaunchMomentHold/surfaceAfter``: it no longer waits silently.
    /// The staged update shows with its reason for a click (Restart to Update installs at once),
    /// and still installs by itself once nothing would be cut off; nothing relaunches over it.
    public var surfaced: Bool

    public init(reason: UpdateRelaunchMoment.Interruption, since: Date, surfaced: Bool = false) {
        self.reason = reason
        self.since = since
        self.surfaced = surfaced
    }

    /// Seconds held at `now`.
    public func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(since)) }

    /// `updates.status`'s `relaunch_hold`: the reason, whether it is surfaced, since when and for how long.
    public func json(at now: Date) -> JSONValue {
        .object(["reason": .string(reason.rawValue), "surfaced": .bool(surfaced),
                 "since": .string(ISO8601DateFormatter().string(from: since)),
                 "age_seconds": .number(age(at: now).rounded())])
    }
}

/// Holds one automatic install until the app's ``UpdateRelaunchMoment`` clears, then runs it once.
///
/// While held it re-reads the moment once a second on one ``DemandTimer``, and on ``recheck()``.
/// It observes no event: the one that announces every end (`NSApplication.didUpdateNotification`)
/// posts after each event-loop pass, so following it cost a main-actor Task per pass while an
/// update waited. Stop condition: the moment clears (the install runs), a newer hold replaces it,
/// or ``cancel()``. Each of them cancels the timers; nothing runs while nothing is held.
///
/// Bound: a hold that lasts ``surfaceAfter`` (`updates.idleInstallMaxWaitSeconds`, 10 minutes by
/// default) is surfaced once (``UpdateRelaunchHoldState/surfaced``, one log line with its reason
/// and age): it stops waiting silently, and the staged update card says why it waits. It never
/// relaunches over the open work.
@MainActor @Observable
final class UpdateRelaunchMomentHold {
    /// The longest a moment that cleared goes unnoticed.
    static let recheckInterval: Duration = .seconds(1)
    /// How long a hold waits silently by default (`updates.idleInstallMaxWaitSeconds`).
    static let defaultSurfaceAfter: Duration = .seconds(600)

    /// The held install, or nil when none waits.
    private(set) var state: UpdateRelaunchHoldState?
    /// How long a hold waits before it is surfaced; a change applies to the next hold.
    @ObservationIgnored var surfaceAfter: Duration = UpdateRelaunchMomentHold.defaultSurfaceAfter
    /// Update When Idle's check, read after the moment's (nil: the setting is off, nothing more holds).
    /// The app answers it from Rust (cmux-window-rules `update_idle`): input within the idle time, an
    /// agent turn, an unsent draft, or any of them unknown holds the install.
    @ObservationIgnored var idleGate: (@MainActor () -> UpdateRelaunchMoment.Interruption?)?

    @ObservationIgnored private let moment: @MainActor () -> UpdateRelaunchMoment
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timer: DemandTimer
    @ObservationIgnored private let bound: DemandTimer
    @ObservationIgnored private let log: (String) -> Void
    @ObservationIgnored private var ready: (@MainActor () -> Void)?
    /// Ends a ``waitUntilClear()`` whose hold is dropped instead of released.
    @ObservationIgnored private var dropped: (() -> Void)?

    init(moment: @escaping @MainActor () -> UpdateRelaunchMoment = { .current() },
         clock: any Clock<Duration> = ContinuousClock(),
         now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = { _ in }) {
        self.moment = moment
        self.now = now
        self.log = log
        timer = DemandTimer(owner: "UpdaterService.relaunchMoment", clock: clock)
        bound = DemandTimer(owner: "UpdaterService.relaunchMomentBound", clock: clock)
    }

    /// Whether an install waits.
    var isHolding: Bool { ready != nil }

    /// False when nothing would be cut off (the caller installs now). Otherwise keeps `ready`,
    /// replacing an earlier hold, and runs it once the moment clears.
    func hold(_ ready: @escaping @MainActor () -> Void) -> Bool {
        cancel()
        guard let reason = interruption() else { return false }
        log("automatic install waits: \(reason)")
        self.ready = ready
        state = UpdateRelaunchHoldState(reason: reason, since: now())
        scheduleRecheck()
        bound.schedule(after: surfaceAfter) { @MainActor [weak self] in self?.surface() }
        return true
    }

    /// Runs the held install if the moment has cleared.
    func recheck() {
        guard let ready else { return }
        guard let reason = interruption() else {
            let held = state.map { " after \(Int($0.age(at: now()))) s" } ?? ""
            log("automatic install: nothing would be cut off now; installing\(held)")
            dropped = nil
            cancel()
            ready()
            return
        }
        if state?.reason != reason { state?.reason = reason }
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
        if interruption() == nil { return true }
        return await waitUntilClear()
    }

    /// Drops the held install without running it.
    func cancel() {
        let drop = dropped
        dropped = nil
        ready = nil
        if state != nil { state = nil }
        timer.cancel()
        bound.cancel()
        drop?()
    }

    /// The hold outlived its bound: say so once, with its reason and age, and show it.
    private func surface() {
        guard isHolding, var held = state, !held.surfaced else { return }
        if let reason = interruption() { held.reason = reason }
        held.surfaced = true
        state = held
        log("automatic install held \(Int(held.age(at: now()))) s: \(held.reason); no longer waiting silently, "
            + "the staged update shows why for a click, and installs by itself once nothing would be cut off")
    }

    /// What a relaunch now would cut off: the moment's reason first, then Update When Idle's.
    private func interruption() -> UpdateRelaunchMoment.Interruption? {
        moment().interruption ?? idleGate?()
    }

    private func scheduleRecheck() {
        timer.schedule(after: Self.recheckInterval) { @MainActor [weak self] in
            guard let self, self.isHolding else { return }
            self.recheck()
            if self.isHolding { self.scheduleRecheck() }
        }
    }
}
