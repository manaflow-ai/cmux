extension CMUXCLI {
    struct AgentHookProcessBindingResult {
        let binding: CallerTerminalBinding?
        let source: AgentHookProcessBindingSource?
        /// The candidate PID that produced `binding`, when the app resolved
        /// that exact process rather than only corroborating the caller TTY.
        let verifiedPID: Int?
        let rejectsAmbientClaim: Bool

        func canReplaceAmbientWorkspace(_ workspaceId: String?) -> Bool {
            guard let workspaceId else { return true }
            return source == .liveProcess || binding?.workspaceId == workspaceId
        }
    }
}
