import AppKit

/// A retained AppKit application reference that can safely cross the resolver
/// queue. Reading `NSRunningApplication.processIdentifier` can make a
/// synchronous LaunchServices request, so the resolver keeps that lookup off
/// the main actor.
nonisolated final class NoActivateApplicationReference: @unchecked Sendable { // crash-allow: immutable AppKit reference is only read by the resolver queue and main handoff.
    let application: NSRunningApplication

    init(_ application: NSRunningApplication) {
        self.application = application
    }
}

/// Under `CMUX_NEXT_NO_ACTIVATE=1` the app must never hold the keyboard
/// unless the user put it there. The app refuses every activation it asks
/// for itself (`CmuxApplication`), but macOS can still activate it (at
/// launch, observed on agent runs) or make a window key. This guard gives
/// the keyboard back when that happens without user intent.
@MainActor
final class NoActivateKeyboardGuard {
    /// What the guard reads and does (AppKit in the app, a fake in tests).
    @MainActor protocol Host: AnyObject {
        /// Input state right now: a pressed mouse button (a click on our
        /// window activates on mouse-down) or a held Command key (Cmd-Tab).
        var mouseButtonDown: Bool { get }
        var commandHeld: Bool { get }
        var isAppActive: Bool { get }
        var now: ContinuousClock.Instant { get }
        /// Hands activation back to `app` (nil: the next app in line).
        /// The object is already supplied by LaunchServices notifications;
        /// implementations must not resolve it from a PID on the main actor.
        func giveActivationBack(to app: NSRunningApplication?)
    }

    enum Trigger: String, Sendable, Equatable {
        case appActivated = "app_activated"
        case windowKey = "window_key"
    }

    struct GiveBack: Sendable, Equatable {
        var trigger: Trigger
        var cause: String
        var restoredTo: pid_t?
    }

    /// Input this recent counts as the user choosing the app.
    static let userInputWindow: Duration = .seconds(1)

    /// Most recent give-backs (bounded), for `debug.focus`.
    private(set) var giveBacks: [GiveBack] = []
    /// Every give-back since launch.
    var giveBackCount: Int { totalGiveBacks }
    private var totalGiveBacks = 0
    private(set) var previousApp: NSRunningApplication?
    private(set) var previousAppPID: pid_t?
    private var pendingApplicationSequence: UInt64 = 0
    private let host: any Host
    private let onGiveBack: (GiveBack) -> Void
    /// Off: the guard gives nothing back (an update relaunch's startup ended).
    var isEnabled = true
    /// The app became active with user intent (a click, Cmd-Tab, recent input): the user chose it.
    var onUserChose: (() -> Void)?
    /// Until then, held Command or a pressed mouse button counts as no intent: they belong to the app
    /// the user is in when LaunchServices activates an update relaunch at launch (a held Cmd-C, a
    /// drag). Set by the update relaunch's startup; nil trusts them at once.
    var ignoresHeldInputUntil: ContinuousClock.Instant?
    /// How long after the guard starts held input is not intent (``ignoresHeldInputUntil``).
    static let launchActivationGrace: Duration = .seconds(2)

    init(host: any Host, frontmost: NSRunningApplication?, frontmostPID: pid_t? = nil,
         onGiveBack: @escaping (GiveBack) -> Void = { _ in }) {
        self.host = host
        previousApp = frontmost
        previousAppPID = frontmostPID
        self.onGiveBack = onGiveBack
    }

    private var lastUserInput: ContinuousClock.Instant?
    /// A give-back was counted and the app has not resigned active since:
    /// further notifications of that activation (didBecomeKey,
    /// didBecomeActive) step aside again without counting.
    private var inGivenBackActivation = false

    /// Checks once when the observers are in place: macOS may have
    /// activated the app before anything observed it.
    func start() { check(.appActivated) }

    /// Another app became frontmost: that is where the keyboard goes back.
    func beginOtherAppActivation() -> UInt64 {
        pendingApplicationSequence &+= 1
        return pendingApplicationSequence
    }

    func otherAppActivated(_ app: NSRunningApplication, processIdentifier: pid_t? = nil,
                           sequence: UInt64? = nil) {
        if let sequence, sequence != pendingApplicationSequence { return }
        previousApp = app
        previousAppPID = processIdentifier
    }

    /// A key press or mouse press reached this app.
    func userInput() { lastUserInput = host.now }

    func appDidBecomeActive() { check(.appActivated) }

    /// A window became key. Only an active app holds the keyboard, so a key
    /// window in an inactive app is left alone.
    func windowDidBecomeKey() { check(.windowKey) }

    /// The app really resigned active: the next activation is a new one.
    func appDidResignActive() { inGivenBackActivation = false }

    /// The user chose this app: a click on its window (the mouse is still
    /// down at activation), Cmd-Tab (Command held), or input this recent.
    private var userIntends: Bool {
        let heldCounts = ignoresHeldInputUntil.map { host.now >= $0 } ?? true
        if heldCounts, host.mouseButtonDown || host.commandHeld { return true }
        guard let lastUserInput else { return false }
        return host.now - lastUserInput <= Self.userInputWindow
    }

    private func check(_ trigger: Trigger) {
        guard isEnabled, host.isAppActive else { return }
        if userIntends {
            onUserChose?()
            return
        }
        if inGivenBackActivation {
            // The same activation's other notification: step aside again, count once.
            host.giveActivationBack(to: previousApp)
            return
        }
        inGivenBackActivation = true
        let giveBack = GiveBack(trigger: trigger, cause: "no_user_input", restoredTo: previousAppPID)
        host.giveActivationBack(to: previousApp)
        giveBacks.append(giveBack)
        totalGiveBacks += 1
        if giveBacks.count > 32 { giveBacks.removeFirst() }
        onGiveBack(giveBack)
    }
}

/// The AppKit host: global input state and cooperative activation.
@MainActor
final class AppKitKeyboardGuardHost: NoActivateKeyboardGuard.Host {
    /// True once the guard stopped (an update relaunch's startup ended): a hand-back still queued
    /// then does nothing, so it never undoes the click that ended it.
    var stopped: () -> Bool = { false }
    var mouseButtonDown: Bool { NSEvent.pressedMouseButtons != 0 }
    var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
    var isAppActive: Bool { NSApp.isActive }
    var now: ContinuousClock.Instant { .now }

    func giveActivationBack(to app: NSRunningApplication?) {
        // Deactivate synchronously so the guard never retains the keyboard.
        // The LaunchServices handoff is deferred and uses the already-resolved
        // object, avoiding both PID lookup and activation work in the observer.
        NSApp.deactivate()
        guard let app else { return }
        let reference = NoActivateApplicationReference(app)
        DispatchQueue.main.async { [weak self] in
            guard self?.stopped() != true, !reference.application.isTerminated else { return }
            NSApp.yieldActivation(to: reference.application)
            _ = reference.application.activate(from: .current, options: [])
        }
    }
}
