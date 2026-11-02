import AppKit
import CmuxNextFocusUI

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
