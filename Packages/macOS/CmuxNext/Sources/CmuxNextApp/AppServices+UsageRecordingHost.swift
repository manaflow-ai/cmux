import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextSettings

// Opt-in usage recording (UsageRecorder, CmuxNextControl): one-line forwards to what it counts and asks with.
extension AppServices: UsageRecordingHost {
    var usageChannel: String { crashReporting.reporter.policy.channel?.rawValue ?? CrashReportingPolicy.Channel.dev.rawValue }
    var usagePreviousRun: String { crashRecovery.marker == nil ? "unknown" : crashRecovery.recovery.isRestart ? "crash" : "clean" }
    var usageWorkspaces: [WorkspaceModel] { daemon.store.workspaces }
    var usageWindowCount: Int { windows.controllers.count }
    var usageSidebarHidden: Bool { windows.active?.state.sidebarHidden ?? true }
    var usageSidebarWidth: Double { Double(windows.active?.sidebar.model.width ?? 0) }
    var usageAppActive: Bool { appActiveSource() }
    func usageConnection() async -> DaemonConnection? {
        if daemon.connection == nil { await daemon.firstConnection() }
        return daemon.connection
    }
    func usageIsChat(_ id: String) -> Bool { agentTabs.isAgentTab(id) }
    func usageAsk(_ title: String, detail: String, yes: String, no: String) async -> Bool { await machineAsks.ask(title, detail: detail, symbol: "chart.bar.xaxis", yes: yes, no: no) }
    nonisolated func usageManagedDisables() -> Bool { ManagedPreferenceLocation.defaultReader().read().forced[CrashReportingPolicy.disableTelemetryPolicyKey]?.boolValue == true }
}
