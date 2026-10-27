import CmuxNextWakeups

extension TerminalAttachment {
    /// Queues an admitted event for the session's event loop, on the attach reader. An `output` marks its
    /// press's decode (`app.output.decoded`); one that echoes key press `flow` goes right after its marker
    /// (``TerminalChannelEvent/inputEcho(flow:)``), so the lane queues that chunk with the flow.
    static func enqueue(_ event: TerminalChannelEvent, echoing flow: UInt64?, on queue: TerminalEventQueue,
                        probe: TypingLatencyProbe) {
        if case .output = event { probe.outputDecoded(flow: flow) }
        if let flow { queue.pushWithoutWaiting(.inputEcho(flow: flow)) }
        queue.push(event)
    }

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
