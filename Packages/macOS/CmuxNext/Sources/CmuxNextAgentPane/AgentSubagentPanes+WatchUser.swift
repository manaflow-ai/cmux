import AppKit
public import CmuxNextAgentPanePlacement
import CmuxNextCompat

// The app's input for AgentSubagentPanes (CmuxNextAgentPanePlacement, which builds without AppKit).
public extension AgentSubagentPanes {
    /// Calls `acted` on the next click or key press in the app, or when another window takes the
    /// keyboard or the app resigns active; returns what stops watching. The `watchUser` hook the
    /// app passes to ``AgentSubagentPanes/Hooks``.
    nonisolated static func watchUser(_ acted: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        SubagentUserInputWatch.start(acted)
    }
}

/// The seam adapter between AppKit's input callbacks and the main actor, for
/// ``AgentSubagentPanes/watchUser(_:)``.
enum SubagentUserInputWatch {
    nonisolated static func start(_ acted: @escaping @MainActor @Sendable () -> Void) -> () -> Void {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            guard Thread.isMainThread else { return event }
            // main-proof: guarded by Thread.isMainThread above (AppKit calls local monitors on main)
            MainActor.assumeIsolated { acted() }
            return event
        }
        let center = NotificationCenter.default
        let observers = [NSWindow.didBecomeKeyNotification, NSApplication.didResignActiveNotification].map { name in
            MainActorObservation(name, center: center) {
                acted()
            }
        }
        return {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach { $0.cancel() }
        }
    }
}
