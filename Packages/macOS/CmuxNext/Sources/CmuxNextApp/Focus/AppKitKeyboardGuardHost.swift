import AppKit
import CmuxNextFocusUI
import CmuxNextWakeups

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

/// The AppKit host: global input state and cooperative activation.
@MainActor
final class AppKitKeyboardGuardHost: NoActivateKeyboardGuard.Host {
    private let mainWork: MainWorkScheduler

    /// - Parameter mainWork: The app's main-thread scheduler; the LaunchServices handoff is a task on it.
    init(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
    }

    var mouseButtonDown: Bool { NSEvent.pressedMouseButtons != 0 }
    var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
    var isAppActive: Bool { NSApp.isActive }
    var now: ContinuousClock.Instant { .now }

    func giveActivationBack(to app: NSRunningApplication?) {
        // Deactivate synchronously so the guard never retains the keyboard.
        // The LaunchServices handoff is a later task and uses the already-resolved
        // object, avoiding both PID lookup and activation work in the observer.
        NSApp.deactivate()
        guard let app else { return }
        mainWork.post(.visible, owner: "NoActivateKeyboardGuard.giveBack") {
            guard !app.isTerminated else { return }
            NSApp.yieldActivation(to: app)
            _ = app.activate(from: .current, options: [])
        }
    }
}
