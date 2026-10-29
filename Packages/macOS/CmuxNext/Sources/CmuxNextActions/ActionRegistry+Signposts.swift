import AppKit

extension ActionRegistry {
    /// Runs one action run's synchronous work inside ``runTiming`` (always-on `action.perform` and
    /// `action.commit` signposts, in Debug and Release). Every run that does work passes here: the
    /// handler (`runScoped`) and a key window's route. Refused runs (disabled feature, unavailable,
    /// refused target) do no work and record nothing. Gates (the confirmation presenter, the
    /// argument collector) are timed apart, by ``gated(_:_:_:)``.
    ///
    /// `index` is the action's interned timing index (``Action/timingIndex``).
    func signposted<T>(_ id: ActionID, index: UInt32, _ invocation: ActionInvocation, _ run: () -> T) -> T {
        endOpenGate()
        return runTiming.time(ActionRunKey(id: id, index: index), invocation.origin, input: { input(of: invocation) }, run)
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
        let end = runTiming.beginGate(id, invocation.origin, input: { input(of: stamped) })
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

    /// The run's input: the person's event's age and the entrypoint, from one read of the event
    /// being dispatched.
    private func input(of invocation: ActionInvocation) -> ActionRunInput {
        let event = invocation.origin == .user ? dispatchingInputEvent() : nil
        let age = Self.inputAgeMilliseconds(origin: invocation.origin, event: event,
                                            carried: invocation.inputTimestamp, now: ProcessInfo.processInfo.systemUptime)
        return ActionRunInput(ageMilliseconds: age, entrypoint: Self.entrypoint(origin: invocation.origin, event: event))
    }

    /// Where a run came from: a person's run by the type of the event being dispatched (a key or
    /// a click; none is ``ActionEntrypoint/unattributed``), any other run by its origin.
    static func entrypoint(origin: ActionOrigin, event: NSEvent?) -> ActionEntrypoint {
        switch event?.type {
        case .keyDown, .keyUp: ActionEntrypoint(origin: origin, isKey: true, isPointer: false)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            ActionEntrypoint(origin: origin, isKey: false, isPointer: true)
        default: ActionEntrypoint(origin: origin, isKey: false, isPointer: false)
        }
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
        guard let stamp = inputTimestamp(of: event) ?? carried, stamp <= now else { return -1 }
        return (now - stamp) * 1_000
    }

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
