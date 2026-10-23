import AppKit

extension ActionRegistry {
    /// Runs one action run's synchronous work inside ``runTiming`` (always-on `action.perform` and
    /// `action.commit` signposts, in Debug and Release). Every run that does work passes here: the
    /// handler (`runScoped`) and a key window's route. Refused runs (disabled feature, unavailable,
    /// refused target) do no work and record nothing. Gates (the confirmation presenter, the
    /// argument collector) are timed apart, by ``gated(_:_:_:)``.
    func signposted<T>(_ id: ActionID, _ invocation: ActionInvocation, _ run: () -> T) -> T {
        endOpenGate()
        return runTiming.time(id, invocation.origin, inputAge: { inputAge(of: invocation) }, run)
    }

    /// Hands an action to a gate (the confirmation presenter or the argument collector) inside an
    /// `action.gate` interval, never the action's own: the gate decides whether and when the
    /// action runs, and the run it lets through is timed on its own.
    ///
    /// `gate` gets the invocation stamped with the timestamp of the input event being dispatched
    /// (``ActionInvocation/inputTimestamp``; an invocation that already carries one keeps it
    /// outside a dispatch), so a run that comes in a later turn (after a `Task`,
    /// a daemon round trip) still reports the age of the press that started it. A gate that runs
    /// the action (or another gate) synchronously ends its interval first, so the intervals never
    /// nest: one Close Workspace press is one gate and one run.
    func gated(_ id: ActionID, _ invocation: ActionInvocation, _ gate: (ActionInvocation) -> Void) {
        var stamped = invocation
        // The press being dispatched now replaces an older stamp: a confirmation the palette's
        // Return asks for answers the Return, not the shortcut that opened the palette.
        if invocation.origin == .user, let timestamp = Self.inputTimestamp(of: dispatchingInputEvent()) {
            stamped.inputTimestamp = timestamp
        }
        endOpenGate()
        let end = runTiming.beginGate(id, invocation.origin, inputAge: { inputAge(of: stamped) })
        openGateEnd = end
        gate(stamped)
        endOpenGate()
    }

    /// Ends the gate interval open now, if any, exactly once.
    private func endOpenGate() {
        guard let end = openGateEnd else { return }
        openGateEnd = nil
        end()
    }

    private func inputAge(of invocation: ActionInvocation) -> Double {
        Self.inputAgeMilliseconds(origin: invocation.origin, event: dispatchingInputEvent(),
                                  carried: invocation.inputTimestamp, now: ProcessInfo.processInfo.systemUptime)
    }

    /// The age in milliseconds of the input a person's run answers; -1 for any other run (socket,
    /// CLI, MCP, script, page, remote) or when there is none.
    ///
    /// The OS input event AppKit is dispatching now (`event`, a key or a click) wins: a run a
    /// confirmation sheet's button or the palette's Return lets through answers that click or key,
    /// not the first press. Outside a dispatch, `carried` (the stamp of the press that started a
    /// gated run, ``ActionInvocation/inputTimestamp``) gives the age. `NSApp.currentEvent` is not
    /// used: it keeps the last event after its dispatch ends, so a socket run minutes after a key
    /// press would report that key's age.
    static func inputAgeMilliseconds(origin: ActionOrigin, event: NSEvent?, carried: Double? = nil,
                                     now: TimeInterval) -> Double {
        guard origin == .user else { return -1 }
        if let stamp = inputTimestamp(of: event) {
            return stamp <= now ? (now - stamp) * 1_000 : -1
        }
        // A carried press 1 s or more old held a person's dwell (a sheet they read, a menu they
        // browsed) and is no input latency; SwitchFrameTimer drops such ages the same way.
        guard let carried, carried <= now, now - carried < Self.carriedPressLimit else { return -1 }
        return (now - carried) * 1_000
    }

    /// The oldest carried press a run still reports (seconds).
    static let carriedPressLimit: TimeInterval = 1

    /// `event`'s timestamp when it is a key or a click, else nil.
    static func inputTimestamp(of event: NSEvent?) -> Double? {
        guard let event else { return nil }
        switch event.type {
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return event.timestamp
        default:
            return nil
        }
    }
}
