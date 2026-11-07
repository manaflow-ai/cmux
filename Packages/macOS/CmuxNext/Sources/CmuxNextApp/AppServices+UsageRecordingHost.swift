import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextSettings

// Opt-in usage recording and team sharing (UsageRecorder, UsageSharing in CmuxNextControl): one-line forwards.
extension AppServices: UsageRecordingHost {
    var usageChannel: String { crashReporting.reporter.policy.channel?.rawValue ?? CrashReportingPolicy.Channel.dev.rawValue }
    var usagePreviousRun: String { crashRecovery.marker == nil ? "unknown" : crashRecovery.recovery.isRestart ? "crash" : "clean" }
    var usageWorkspaces: [WorkspaceModel] { daemon.store.workspaces }
    var usageWindowCount: Int { windows.controllers.count }
    var usageSidebarWidth: Double { windows.active.map { $0.state.sidebarHidden ? 0 : Double($0.sidebar.model.width) } ?? 0 }
    var usageAppActive: Bool { appActiveSource() }
    func usageConnection() async -> DaemonConnection? { await daemon.connectionAfterFirst() }
    func usageIsChat(_ id: String) -> Bool { agentTabs.isAgentTab(id) }
    func usageAsk(_ title: String, detail: String, yes: String, no: String) async -> Bool { await machineAsks.ask(title, detail: detail, symbol: "chart.bar.xaxis", yes: yes, no: no) }
    nonisolated func usageManagedDisables() -> Bool { ManagedPreferenceLocation.defaultReader().read().forced[CrashReportingPolicy.disableTelemetryPolicyKey]?.boolValue == true }
    var usageCLI: BundledExecutable { bundledCLI }
    func usageShareAccess() async -> UsageShareAccess? { guard cloud.isSignedIn, let token = try? await cloud.installIdentity.accessToken(team: cloud.auth.accessTokenTeam(requested: nil)) else { return nil }; return UsageShareAccess(platform: cloud.configuration.relayAPIBaseURL(), credential: token.accessToken) }
}
