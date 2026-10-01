import AppKit

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
        func giveActivationBack(to app: pid_t?)
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
    private(set) var previousApp: pid_t?
    private let host: any Host
    private let onGiveBack: (GiveBack) -> Void

    init(host: any Host, frontmost: pid_t?, onGiveBack: @escaping (GiveBack) -> Void = { _ in }) {
        self.host = host
        previousApp = frontmost
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
    func otherAppActivated(_ pid: pid_t) { previousApp = pid }

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
        if host.mouseButtonDown || host.commandHeld { return true }
        guard let lastUserInput else { return false }
        return host.now - lastUserInput <= Self.userInputWindow
    }

    private func check(_ trigger: Trigger) {
        guard host.isAppActive, !userIntends else { return }
        if inGivenBackActivation {
            // The same activation's other notification: step aside again, count once.
            host.giveActivationBack(to: previousApp)
            return
        }
        inGivenBackActivation = true
        let giveBack = GiveBack(trigger: trigger, cause: "no_user_input", restoredTo: previousApp)
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
    var mouseButtonDown: Bool { NSEvent.pressedMouseButtons != 0 }
    var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
    var isAppActive: Bool { NSApp.isActive }
    var now: ContinuousClock.Instant { .now }

    func giveActivationBack(to app: pid_t?) {
        if let app, let running = NSRunningApplication(processIdentifier: app), !running.isTerminated {
            NSApp.yieldActivation(to: running)
            running.activate(from: .current, options: [])
        }
        // With no app to hand to (or if it refused), step aside anyway.
        NSApp.deactivate()
    }
}
