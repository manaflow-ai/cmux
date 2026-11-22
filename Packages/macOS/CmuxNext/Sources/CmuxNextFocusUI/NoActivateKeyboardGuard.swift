public import AppKit

/// Under `CMUX_NEXT_NO_ACTIVATE=1` the app must never hold the keyboard
/// unless the user put it there. The app refuses every activation it asks
/// for itself (`CmuxApplication`), but macOS can still activate it (at
/// launch, observed on agent runs) or make a window key. This guard gives
/// the keyboard back when that happens without user intent.
@MainActor
public final class NoActivateKeyboardGuard {
    /// What the guard reads and does (AppKit in the app, a fake in tests).
    @MainActor public protocol Host: AnyObject {
        /// Input state right now: a pressed mouse button (a click on our
        /// window activates on mouse-down) or a held Command key (Cmd-Tab).
        var mouseButtonDown: Bool { get }
        var commandHeld: Bool { get }
        var isAppActive: Bool { get }
        var now: ContinuousClock.Instant { get }
        /// Runs `body` once after `delay` (an injected clock in the app; tests run it by hand).
        func schedule(after delay: Duration, _ body: @escaping @MainActor @Sendable () -> Void)
        /// Hands activation back to `app` (nil: the next app in line).
        /// The object is already supplied by LaunchServices notifications;
        /// implementations must not resolve it from a PID on the main actor.
        func giveActivationBack(to app: NSRunningApplication?)
    }

    public enum Trigger: String, Sendable, Equatable {
        case appActivated = "app_activated"
        case windowKey = "window_key"
    }

    public struct GiveBack: Sendable, Equatable {
        public var trigger: Trigger
        public var cause: String
        public var restoredTo: pid_t?
    }

    /// Input this recent counts as the user choosing the app.
    public static let userInputWindow: Duration = .seconds(1)
    /// How long an activation with no intent seen yet waits for the input that caused it before
    /// the front goes back (https://github.com/manaflow-ai/cmux/issues/34575): macOS posts the
    /// activation before the app dispatches the click's mouse-down, and a Dock click or an open
    /// (Tag Opener, Finder) reaches the app as a reopen after it. Without the wait, every click on
    /// an agent-launched build handed the front straight back to the app the user came from.
    public static let intentArrivalWindow: Duration = .milliseconds(300)

    /// Most recent give-backs (bounded), for `debug.focus`.
    public private(set) var giveBacks: [GiveBack] = []
    /// Every give-back since launch.
    public var giveBackCount: Int { totalGiveBacks }
    private var totalGiveBacks = 0
    public private(set) var previousApp: NSRunningApplication?
    public private(set) var previousAppPID: pid_t?
    private var pendingApplicationSequence: UInt64 = 0
    private let host: any Host
    private let onGiveBack: (GiveBack) -> Void
    /// Off: the guard gives nothing back (an update relaunch's startup ended).
    public var isEnabled = true
    /// The app became active with user intent (a click, Cmd-Tab, recent input): the user chose it.
    public var onUserChose: (() -> Void)?
    /// Until then, held Command or a pressed mouse button counts as no intent: they belong to the app
    /// the user is in when LaunchServices activates an update relaunch at launch (a held Cmd-C, a
    /// drag). Set by the update relaunch's startup; nil trusts them at once.
    public var ignoresHeldInputUntil: ContinuousClock.Instant?
    /// How long after the guard starts held input is not intent (``ignoresHeldInputUntil``).
    public static let launchActivationGrace: Duration = .seconds(2)

    public init(host: any Host, frontmost: NSRunningApplication?, frontmostPID: pid_t? = nil,
         onGiveBack: @escaping (GiveBack) -> Void = { _ in }) {
        self.host = host
        previousApp = frontmost
        previousAppPID = frontmostPID
        self.onGiveBack = onGiveBack
    }

    private var lastUserInput: ContinuousClock.Instant?
    /// The last reopen (``reopenRequested()``): intent only for ``intentArrivalWindow``.
    private var lastReopen: ContinuousClock.Instant?
    /// When the waiting activation began: a key typed after it is meant for the app the person is
    /// in, not a choice of this one.
    private var waitStartedAt: ContinuousClock.Instant?
    /// Until then an activation goes back without waiting: it is the launch's (``start()``).
    private var launchActivationUntil: ContinuousClock.Instant?
    /// A give-back was counted and the app has not resigned active since:
    /// further notifications of that activation (didBecomeKey,
    /// didBecomeActive) step aside again without counting.
    private var inGivenBackActivation = false
    /// The activation waiting for its intent (``intentArrivalWindow``), by the trigger seen first.
    private var waitingTrigger: Trigger?
    /// Bumped whenever a wait ends, so a wait's deadline only settles its own activation.
    private var waitGeneration: UInt64 = 0

    /// Checks once when the observers are in place: macOS may have
    /// activated the app before anything observed it. A launch activation
    /// goes back at once (nothing the user did caused it).
    public func start() {
        launchActivationUntil = host.now + Self.launchActivationGrace
        check(.appActivated, waits: false)
    }

    /// Another app became frontmost: that is where the keyboard goes back.
    public func beginOtherAppActivation() -> UInt64 {
        pendingApplicationSequence &+= 1
        return pendingApplicationSequence
    }

    public func otherAppActivated(_ app: NSRunningApplication, processIdentifier: pid_t? = nil,
                           sequence: UInt64? = nil) {
        if let sequence, sequence != pendingApplicationSequence { return }
        previousApp = app
        previousAppPID = processIdentifier
    }

    /// A key press or mouse press reached this app. Only a press of a pointer button ends an
    /// activation's wait (the click that activated it); a key typed during the wait belongs to the
    /// app the person is in, so it is not intent.
    public func userInput(pointer: Bool = true) {
        lastUserInput = host.now
        if pointer { keepWaitingActivation() }
    }

    /// The app was asked to reopen: a Dock click, or an open of the running app (the Tag Opener,
    /// Finder, `open`). The person asked for this app, so an activation it brings just before or
    /// just after (``intentArrivalWindow``) stays. An `open -g` reopens without activating.
    public func reopenRequested() {
        lastReopen = host.now
        keepWaitingActivation()
    }

    private func keepWaitingActivation() {
        guard waitingTrigger != nil, isEnabled, host.isAppActive else { return }
        endWait()
        onUserChose?()
    }

    public func appDidBecomeActive() { check(.appActivated) }

    /// A window became key. Only an active app holds the keyboard, so a key
    /// window in an inactive app is left alone.
    public func windowDidBecomeKey() { check(.windowKey) }

    /// The app really resigned active: the next activation is a new one.
    public func appDidResignActive() {
        inGivenBackActivation = false
        endWait()
    }

    /// The user chose this app: a click on its window (the mouse is still
    /// down at activation), Cmd-Tab (Command held), or input this recent.
    private var userIntends: Bool {
        let heldCounts = ignoresHeldInputUntil.map { host.now >= $0 } ?? true
        if heldCounts, host.mouseButtonDown || host.commandHeld { return true }
        if let lastReopen, host.now - lastReopen <= Self.intentArrivalWindow { return true }
        guard let lastUserInput, host.now - lastUserInput <= Self.userInputWindow else { return false }
        // Input during the wait: a click ended the wait already, so this is a key typed after the
        // activation began (meant for the person's app).
        if let waitStartedAt, lastUserInput >= waitStartedAt { return false }
        return true
    }

    private func check(_ trigger: Trigger, waits: Bool = true) {
        guard isEnabled, host.isAppActive else { return }
        if userIntends {
            endWait()
            onUserChose?()
            return
        }
        if inGivenBackActivation {
            // The same activation's other notification: step aside again, count once.
            host.giveActivationBack(to: previousApp)
            return
        }
        let launching = launchActivationUntil.map { host.now < $0 } ?? false
        guard waits, !launching else { return giveBack(trigger) }
        // The activation's other notification while it waits: one wait settles it.
        guard waitingTrigger == nil else { return }
        waitingTrigger = trigger
        waitStartedAt = host.now
        let generation = waitGeneration
        host.schedule(after: Self.intentArrivalWindow) { [weak self] in self?.settleWait(generation) }
    }

    /// The wait ended with no intent seen: the front goes back unless the app resigned meanwhile.
    private func settleWait(_ generation: UInt64) {
        guard generation == waitGeneration, let trigger = waitingTrigger else { return }
        // Read before the wait ends: a key typed during it is not intent (``waitStartedAt``).
        let intends = userIntends
        endWait()
        guard isEnabled, host.isAppActive else { return }
        if intends {
            onUserChose?()
            return
        }
        giveBack(trigger)
    }

    private func endWait() {
        guard waitingTrigger != nil else { return }
        waitingTrigger = nil
        waitStartedAt = nil
        waitGeneration &+= 1
    }

    private func giveBack(_ trigger: Trigger) {
        inGivenBackActivation = true
        let giveBack = GiveBack(trigger: trigger, cause: "no_user_input", restoredTo: previousAppPID)
        host.giveActivationBack(to: previousApp)
        giveBacks.append(giveBack)
        totalGiveBacks += 1
        if giveBacks.count > 32 { giveBacks.removeFirst() }
        onGiveBack(giveBack)
    }
}
