/// A first-time action that marks a step of activation. Each fires at most
/// once per install.
///
/// There is no "first terminal" milestone: every launch opens a terminal, so
/// it would only duplicate ``firstLaunch``.
public enum ActivationMilestone: String, Sendable, CaseIterable {
    case firstLaunch = "first_launch"
    /// A workspace the user created, beyond the one every launch opens.
    case firstWorkspace = "first_workspace"
    case firstSplit = "first_split"
    case firstBrowserPane = "first_browser_pane"
    case firstAgentSession = "first_agent_session"
    case firstSignIn = "first_sign_in"
    case firstUpgradeClick = "first_upgrade_click"
    case firstCloudEnable = "first_cloud_enable"
    case firstCloudMachine = "first_cloud_machine"
    case firstCloudWorkspace = "first_cloud_workspace"
    case firstPaidPlan = "first_paid_plan"
}
