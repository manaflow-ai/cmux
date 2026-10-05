@testable import CmuxNextAgentPane

/// A stand-in for the daemon's `_acpmux/web_modes` answer, for tests that have no daemon socket.
/// It models acpmux `web_modes.rs` (the Claude row of `ASKING_MODES`, `MODE_FIELDS`,
/// `FREE_CONFIG_IDS`, `config_value_asks`). The host itself never copies these lists: in the app it
/// asks the daemon, and without an answer it fails closed.
enum AcpmuxAskingModesFake {
    static let modeFields: Set<String> = ["modeId", "mode", "permissionMode", "permission_mode", "approvalPolicy",
                                          "approval_policy", "sandbox", "sandboxMode", "sandbox_mode"]
    static let freeConfigIds: Set<String> = ["model", "effort", "reasoning_effort", "thought_level", "thinking"]

    static let claude: @MainActor (_ sessionId: String?, _ configId: String?, _ value: String?) async -> AcpmuxWebModes? = {
        session, configId, value in
        let asks: Bool? = session == nil || value == nil ? nil
            : freeConfigIds.contains(configId ?? "") || (configId == "mode" && ["default", "plan"].contains(value!))
        return AcpmuxWebModes(modeFields: modeFields, freeConfigIds: freeConfigIds, asks: asks)
    }
}
