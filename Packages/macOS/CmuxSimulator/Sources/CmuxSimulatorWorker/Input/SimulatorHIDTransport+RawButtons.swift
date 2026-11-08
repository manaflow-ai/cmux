import CmuxSimulator

extension SimulatorHIDTransport {
    @discardableResult
    func send(_ event: SimulatorHIDButtonEvent) -> Bool {
        let sent: Bool
        if let modernTransport {
            sent = modernTransport.sendButton(
                page: event.button.page,
                usage: event.button.usage,
                down: event.phase == .down
            )
        } else {
            sent = sendArbitraryHID(
                page: event.button.page,
                usage: event.button.usage,
                direction: event.phase == .down ? 1 : 2
            )
        }
        guard sent else { return false }
        heldButtons.record(event)
        return true
    }
}
