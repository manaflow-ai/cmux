extension CMUXCLI {
    struct AgentHookProcessBindingResult {
        let binding: CallerTerminalBinding?
        let source: AgentHookProcessBindingSource?
        let rejectsAmbientClaim: Bool

        func canReplaceAmbientWorkspace(_ workspaceId: String?) -> Bool {
            guard let workspaceId else { return true }
            return source == .liveProcess || binding?.workspaceId == workspaceId
        }
    }
}
