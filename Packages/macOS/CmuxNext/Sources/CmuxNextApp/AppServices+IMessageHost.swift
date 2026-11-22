import CmuxNextAgentPermissions
import CmuxNextAgentPane
import CmuxNextSettings

extension AppServices: AgentPaneIMessageHost {
    var imessageSettings: SettingsController? { settings }
    func imessageHasFullDiskAccess() async -> Bool { await agentPermissions.probe.status(.fullDiskAccess, target: nil) == .granted }
    func imessageHasAutomation() async -> Bool { await agentPermissions.probe.status(.automation, target: "com.apple.MobileSMS") == .granted }
    func imessageAskAutomation() async { _ = await SystemPermissionAccess().automation(of: "com.apple.MobileSMS", ask: true) }
    func imessageOpenFullDiskAccess() { agentPermissions.opener.open(.fullDiskAccess, target: nil) }
    func imessagePermissionChanges() -> AsyncStream<Void> { agentPermissions.probe.changes() }
}
