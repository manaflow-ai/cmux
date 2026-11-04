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
    /// True once the guard stopped (an update relaunch's startup ended): a hand-back still queued
    /// then does nothing, so it never undoes the click that ended it.
    var stopped: () -> Bool = { false }
    var mouseButtonDown: Bool { NSEvent.pressedMouseButtons != 0 }
    var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
    var isAppActive: Bool { NSApp.isActive }
    var now: ContinuousClock.Instant { .now }
    private let intentWait = DemandTimer(owner: "NoActivateKeyboardGuard.intentArrival")

    func recentClickOnAppOrDock(within window: Duration) -> Bool {
        // Real input only (`hidSystemState`): an automation driver posting to the app's pid is not
        // the person, and does not show here.
        let limit = Double(window.components.seconds) + Double(window.components.attoseconds) * 1e-18
        let sinceDown = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        guard sinceDown <= limit else { return false }
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return false }
        if NSApp.window(withWindowNumber: number) != nil { return true }
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let owner = info.first else { return false }
        if let pid = owner[kCGWindowOwnerPID as String] as? Int, pid == Int(getpid()) { return true }
        return owner[kCGWindowOwnerName as String] as? String == "Dock"
    }

    func schedule(after delay: Duration, _ body: @escaping @MainActor @Sendable () -> Void) {
        intentWait.schedule(after: delay) { @MainActor in body() }
    }

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
