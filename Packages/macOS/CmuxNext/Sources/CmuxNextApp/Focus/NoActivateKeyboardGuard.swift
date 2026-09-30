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

    private(set) var giveBacks: [GiveBack] = []
    private(set) var previousApp: pid_t?
    private let host: any Host
    private let onGiveBack: (GiveBack) -> Void

    init(host: any Host, frontmost: pid_t?, onGiveBack: @escaping (GiveBack) -> Void = { _ in }) {
        self.host = host
        previousApp = frontmost
        self.onGiveBack = onGiveBack
    }

    /// Another app became frontmost: that is where the keyboard goes back.
    func otherAppActivated(_ pid: pid_t) {}

    /// A key press or mouse press reached this app.
    func userInput() {}

    func appDidBecomeActive() {}

    func windowDidBecomeKey() {}
}
