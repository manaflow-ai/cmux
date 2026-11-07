import CmuxNextAgentPane

/// Share with Me on a teammate's Cloud machine's refused chat start (the agent pane's
/// `machine.share.self`). Chat grants lived only on the classic Cloud API (`/api/vm`), which knows no
/// NEXT machine, so this refuses (after the sign-in check) until the platform serves them.
@MainActor
enum CloudMachineShare {
    static func shareWithMe(_ session: CloudMachineSession, cloud: CloudService) async -> AgentPaneMachineShare {
        guard cloud.auth.user?.id != nil else { return .refused(code: "not_signed_in", message: CloudStrings.signInFirst) }
        return .refused(code: "unavailable", message: CloudShareStrings.notCloudMachine)
    }
}
