#if DEBUG
import AppKit
import CmuxNextAgentPane

/// How DEBUG automation (`debug.key`, `debug.agent_pane click`) delivers a synthesized native
/// event so that it is input as the app sees a real one, local event monitors included (the agent
/// pane's gesture monitor records the user's gesture there, ``AgentPaneUserGestures``).
///
/// - The target window is the key window: `NSApp.sendEvent`, the path of a real event.
/// - Any other window (a no-activate agent run has no key window): AppKit would drop a key there
///   (it sends keys only to the key window) and hold back a first click (`acceptsFirstMouse`), so
///   the caller delivers the event itself; first this runs the gesture monitor handler of each
///   agent pane in that window on it, as the local monitor would.
@MainActor
enum DebugNativeInput {
    /// Whether `window` gets events by the real AppKit path.
    static func usesAppKitPath(_ window: NSWindow) -> Bool { NSApp.keyWindow === window }

    /// The real path: the events go through `CmuxApplication.sendEvent` and its local monitors.
    static func sendThroughApp(_ events: [NSEvent]) {
        SyntheticInput.register(events)
        for event in events { NSApp.sendEvent(event) }
    }

    /// The agent panes' gesture monitors in `window`, on `event` (each pane decides by its own
    /// focus and bounds at this moment, as for a real event).
    static func runPaneMonitors(_ event: NSEvent, in window: NSWindow, services: AppServices) {
        for view in services.agentTabs.views.values where view.window === window {
            view.debugRunGestureMonitor(event)
        }
    }
}
#endif
