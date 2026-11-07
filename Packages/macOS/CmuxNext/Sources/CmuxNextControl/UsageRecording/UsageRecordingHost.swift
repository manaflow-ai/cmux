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
    /// The active window's sidebar is hidden (true with no window).
    var usageSidebarHidden: Bool { get }
    /// The active window's sidebar width in points.
    var usageSidebarWidth: Double { get }
    /// The app is active.
    var usageAppActive: Bool { get }
    /// The local daemon's connection now (nil: not connected).
    var usageConnection: DaemonConnection? { get }
    /// Whether tab `id` is an agent chat.
    func usageIsChat(_ id: String) -> Bool
    /// The confirm card on the sidebar's notice card: true for `yes`.
    func usageAsk(_ title: String, detail: String, yes: String, no: String) async -> Bool
    /// Whether a managed profile forces `DisableTelemetry` (reads the managed preferences: off main).
    nonisolated func usageManagedDisables() -> Bool
}
