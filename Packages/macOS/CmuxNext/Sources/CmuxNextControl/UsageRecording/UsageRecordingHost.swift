public import CmuxNextDaemon

/// What ``UsageRecorder`` reads from the app: one-line forwards `AppServices` gives
/// (`AppServices+UsageRecordingHost.swift`).
@MainActor
public protocol UsageRecordingHost: AnyObject, Sendable {
    /// `nightly`, `dev`, `rc` or `release`.
    var usageChannel: String { get }
    /// How the previous run ended: `clean`, `crash`, `hang` or `unknown`.
    var usagePreviousRun: String { get }
    /// The local daemon's workspaces.
    var usageWorkspaces: [WorkspaceModel] { get }
    /// Open windows.
    var usageWindowCount: Int { get }
    /// The active window's sidebar width in points; 0 while it is hidden or with no window.
    var usageSidebarWidth: Double { get }
    /// The app is active.
    var usageAppActive: Bool { get }
    /// The local daemon's connection, once the first one is made (nil: startup gave up). The
    /// recorder's first decision comes from the settings load, before the daemon connects.
    func usageConnection() async -> DaemonConnection?
    /// Whether tab `id` is an agent chat.
    func usageIsChat(_ id: String) -> Bool
    /// The confirm card on the sidebar's notice card: true for `yes`.
    func usageAsk(_ title: String, detail: String, yes: String, no: String) async -> Bool
    /// Whether a managed profile forces `DisableTelemetry` (reads the managed preferences: off main).
    nonisolated func usageManagedDisables() -> Bool
    /// The bundled `cmux` that runs `cmux usage upload` (team sharing).
    var usageCLI: BundledExecutable { get }
    /// The selected backend's platform and a fresh install token, or nil when signed out.
    func usageShareAccess() async -> UsageShareAccess?
}
