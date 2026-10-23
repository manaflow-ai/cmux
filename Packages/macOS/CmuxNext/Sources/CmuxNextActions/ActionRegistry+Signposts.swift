import AppKit

extension ActionRegistry {
    /// Runs one action run's synchronous work inside ``runTiming`` (always-on `action.perform` and
    /// `action.commit` signposts, in Debug and Release). Every run that does work passes here: the
    /// handler (`runScoped`), a key window's route, the palette asking for missing arguments, and
    /// the confirmation sheet of a destructive action. Refused runs (disabled feature, unavailable,
    /// refused target) do no work and record nothing.
    func signposted<T>(_ id: ActionID, _ invocation: ActionInvocation, _ run: () -> T) -> T {
        runTiming.time(id, invocation.origin, inputAge: {
            Self.inputAgeMilliseconds(origin: invocation.origin, event: dispatchingInputEvent(),
                                      now: ProcessInfo.processInfo.systemUptime)
        }, run)
    }

    /// The age in milliseconds of `event`, the OS input event AppKit is dispatching now, for a run
    /// a person started in this app; -1 for any other run (socket, CLI, MCP, script, page,
    /// remote), outside a dispatch, or for an event that is no key or click.
    ///
    /// `NSApp.currentEvent` alone is not enough: it keeps the last event after its dispatch
    /// ends, so a socket run minutes after a key press would report that key's age.
    static func inputAgeMilliseconds(origin: ActionOrigin, event: NSEvent?, now: TimeInterval) -> Double {
        guard origin == .user, let event else { return -1 }
        switch event.type {
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return (now - event.timestamp) * 1_000
        default:
            return -1
        }
    }
}
