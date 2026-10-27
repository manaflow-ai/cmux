import CmuxNextWakeups

extension TerminalAttachment {
    /// The next event for the session's event loop, which awaits it. An echo's marker
    /// (``TerminalChannelEvent/inputEcho(flow:)``, just before its chunk) ends the attach reader's handoff of the
    /// echo here and begins the loop's handoff to the lane's router (p09-observability-102).
    static func next(from queue: TerminalEventQueue, marking probe: TypingLatencyProbe) async -> TerminalChannelEvent? {
        let event = await queue.next()
        if case .inputEcho(let flow)? = event {
            probe.taken(.appTransportRead, flow: flow)
            probe.queued(.mainActor, flow: flow)
        }
        return event
    }
}
