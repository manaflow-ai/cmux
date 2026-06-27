public import AppKit

/// App-target seam for the window-teardown effect the
/// ``WindowLifecycleCoordinator`` drives but cannot own.
///
/// The coordinator owns window identity and the close-broadcast subscription
/// (`windowCoordinator` plus its single-consumer closure task), but the full
/// teardown that each close triggers (`unregisterMainWindow`: geometry persist,
/// closed-window history, active-window repoint, snapshot save, palette removal,
/// notification clearing) reaches deep into `@main` app-delegate state that lives
/// app-side. The app delegate conforms and injects itself as the host so the
/// window-lifecycle orchestration layer stays in this package while that app-only
/// teardown stays where its state lives.
///
/// `AnyObject` + held `weak` by the coordinator so the app delegate ↔ coordinator
/// reference is one-directional in ownership: the app delegate owns the
/// coordinator strongly; the coordinator weak-refs back, so there is no retain
/// cycle (mirrors the notification-nav seam adapter pattern).
@MainActor
public protocol WindowLifecycleHosting: AnyObject {
    /// Runs the full teardown for a closing main `window`: cascade-point reset,
    /// closed-window history, geometry persist, context unregistration, palette
    /// and notification cleanup, and active-window repoint. Driven once per
    /// window from the coordinator's close-broadcast subscription.
    func unregisterMainWindow(_ window: NSWindow)
}
