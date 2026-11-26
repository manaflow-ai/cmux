extension AgentPaneTransport {
    /// `sessions.allowFullAccess` off: a switch into a mode that skips approvals is answered here, by
    /// session/set_mode or by any config option whose value is such a mode. acpmux enforces the same
    /// setting for every client (hub/start_mode.rs); this answers the page without the round trip.
    func fullAccessRefusal(_ facts: Facts, socket: AcpmuxPaneSocket) -> Step? {
        guard let setting = facts.setting, !allowsFullAccess() else { return nil }
        let value: String = switch setting.asked {
        case .mode(let mode): mode
        case .option(_, let value): value
        }
        guard AgentPaneModeConfirmation.isFullAccess(value) else { return nil }
        return Self.refuse(.refuse(.fullAccessOff, method: facts.method, requestID: facts.pageID), socket: socket)
    }
}
