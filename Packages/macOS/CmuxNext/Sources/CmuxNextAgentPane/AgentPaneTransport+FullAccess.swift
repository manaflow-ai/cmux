extension AgentPaneTransport {
    /// `sessions.allowFullAccess` off: a switch into a mode that skips approvals is refused, by
    /// set_mode or by the `mode` config option alike. Other modes and options are unchanged.
    func fullAccessRefusal(_ facts: Facts, socket: AcpmuxPaneSocket) -> Step? {
        guard let setting = facts.setting, case .mode(let mode) = setting.asked,
              AgentPaneModeConfirmation.isFullAccess(mode), !allowsFullAccess() else { return nil }
        return Self.refuse(.refuse(.fullAccessOff, method: facts.method, requestID: facts.pageID), socket: socket)
    }
}
