public import Foundation

/// The live-workspace reads and mutations ``WorkspaceSurfaceMetadataModel``
/// reaches back into.
///
/// ``WorkspaceSurfaceMetadataModel`` owns the per-surface directory and
/// listening-port half of the registry (through the shared
/// ``SurfaceRegistryModel`` it is constructed with) and the pure
/// directory-resolution / unmounted-volume-guard logic the legacy `Workspace`
/// god object kept inline. Everything those bodies touched that is *not*
/// registry state, the workspace's focused panel, its `@Published`
/// `currentDirectory` / `surfaceTabBarDirectory` (whose `didSet` posts the
/// sidebar-refresh notification and must keep firing), the remote-tmux-mirror
/// flag, a terminal panel's requested working directory, the
/// restored-guarded-directory bookkeeping, the agent/remote port sets, and the
/// DEBUG ignore log, is irreducibly app-coupled, so the model calls it through
/// this seam. The fused `listeningPorts` projection and the conversation /
/// submitted-message previews now live on ``WorkspaceSurfaceMetadataModel``
/// itself (with their own Combine publishers), so they no longer round-trip
/// through this seam. The app target's `Workspace` conforms and is injected via
/// ``WorkspaceSurfaceMetadataModel/attach(host:)``.
///
/// Every member mirrors a read or write the legacy method bodies made on
/// `self` (`focusedPanelId`, `currentDirectory`, `surfaceTabBarDirectory`,
/// `isRemoteTmuxMirror`, `terminalPanel(for:)?.requestedWorkingDirectory`,
/// `restoredGuardedWorkingDirectoriesByPanelId`, `agentListeningPorts`,
/// `remoteDetectedPorts`, `remoteForwardedPorts`) so the move is byte-faithful.
@MainActor
public protocol SurfaceMetadataHosting: AnyObject {
    /// The focused panel id, or `nil` when the workspace has no focus
    /// (legacy `Workspace.focusedPanelId`).
    var surfaceMetadataFocusedPanelId: UUID? { get }

    /// Whether a panel with `panelId` currently exists in the workspace
    /// (legacy `Workspace.panels[panelId] != nil`).
    /// ``WorkspaceSurfaceMetadataModel/applyPanelShellActivityState(panelId:state:)``
    /// ignores a shell-activity report for an absent panel exactly as the
    /// legacy body did.
    func surfaceMetadataPanelExists(panelId: UUID) -> Bool

    /// The workspace's current working directory (legacy
    /// `Workspace.currentDirectory`). The setter is the `@Published` property
    /// whose `didSet` posts `.workspaceCurrentDirectoryDidChange`; the model
    /// only assigns it inside the focused-panel branch exactly as the legacy
    /// body did.
    var surfaceMetadataCurrentDirectory: String { get set }

    /// The directory shown in the surface tab bar (legacy
    /// `Workspace.surfaceTabBarDirectory`). The model assigns it inside the
    /// focused-panel branch exactly as the legacy body did.
    var surfaceMetadataSurfaceTabBarDirectory: String? { get set }

    /// Whether this workspace mirrors a remote tmux session (legacy
    /// `Workspace.isRemoteTmuxMirror`). A mirror's directories are remote
    /// paths, so ``WorkspaceSurfaceMetadataModel/configTrackingDirectory(for:)``
    /// returns `nil` for one.
    var surfaceMetadataIsRemoteTmuxMirror: Bool { get }

    /// Whether the workspace is using remote-directory provenance, so local
    /// cmux.json tracking must not follow remote paths.
    var surfaceMetadataUsesRemoteDirectoryProvenance: Bool { get }

    /// Whether `panelId` may fall back to local directory state when a trusted
    /// remote report has not been established.
    func surfaceMetadataAllowsLocalDirectoryFallback(panelId: UUID) -> Bool

    /// The requested working directory of the terminal panel with `panelId`,
    /// or `nil` when the panel is absent or not a terminal (legacy
    /// `terminalPanel(for: panelId)?.requestedWorkingDirectory`).
    func surfaceMetadataRequestedWorkingDirectory(panelId: UUID) -> String?

    /// The directory a guarded surface was restored with, used to ignore the
    /// first live cwd report while its volume is still unmounted (legacy
    /// `restoredGuardedWorkingDirectoriesByPanelId[panelId]`).
    func surfaceMetadataRestoredGuardedWorkingDirectory(panelId: UUID) -> String?

    /// Clears a panel's restored-guarded-directory entry once the guard no
    /// longer applies (legacy
    /// `restoredGuardedWorkingDirectoriesByPanelId.removeValue(forKey:)`).
    func surfaceMetadataClearRestoredGuardedWorkingDirectory(panelId: UUID)

    /// Clears a panel's restored resume-session directory when the restored
    /// directory no longer exists.
    func surfaceMetadataClearRestoredResumeSessionWorkingDirectory(panelId: UUID)

    /// The agent-discovered listening ports (legacy
    /// `Workspace.agentListeningPorts`).
    var surfaceMetadataAgentListeningPorts: [Int] { get }

    /// The remote-detected listening ports (legacy
    /// `Workspace.remoteDetectedPorts`).
    var surfaceMetadataRemoteDetectedPorts: [Int] { get }

    /// The remote-forwarded listening ports (legacy
    /// `Workspace.remoteForwardedPorts`).
    var surfaceMetadataRemoteForwardedPorts: [Int] { get }

    /// Emits the DEBUG `session.restore.cwdReport.ignored` log line the legacy
    /// `shouldIgnoreRestoredGuardedDirectoryReport` wrote when it ignored a
    /// report. A no-op in release builds; kept on the host so the
    /// `cmuxDebugLog` sink and its workspace-id prefix stay app-side.
    func surfaceMetadataLogIgnoredRestoredCwdReport(
        panelId: UUID,
        missingVolumeRoot: String,
        savedDirectory: String,
        reportedDirectory: String
    )

    /// Emits the DEBUG `session.restore.cwdReport.ignoredOnce/accepted` log
    /// line for restored cwd fallback handling.
    func surfaceMetadataLogRestoredCwdDecision(
        panelId: UUID,
        event: String,
        savedDirectory: String,
        reportedDirectory: String
    )
}
