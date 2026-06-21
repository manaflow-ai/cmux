public import Foundation
public import CmuxCore

/// The live-workspace operations ``AgentForkCoordinator`` reaches back into.
///
/// ``AgentForkCoordinator`` owns the agent-conversation *fork* orchestration the
/// legacy `Workspace` god object kept inline (`forkAgentWorkspaceLaunch`,
/// `forkAgentConversation` for a split, `forkAgentWorkingDirectory`,
/// `canForkAgentConversationFromPanel`, `forkableAgentSnapshot`,
/// `forkAgentConversationToNewTab`, `forkAgentRemoteStartupCommand`,
/// `forkAgentRemoteConfigurationForNewWorkspace`, and the post-class
/// `forkAgentConversation(destination:)` / `forkAgentConversationToNewWorkspace`
/// dispatch). The coordinator sequences the guard ordering, the
/// local-vs-remote-fork branching, the descriptor assembly, the zoom
/// save/restore around a split, and the destination dispatch; everything that
/// touches the live window is irreducibly app-coupled and reached through this
/// seam: the live panel set and remote-terminal classification, the resolved
/// fork working directory and startup input, the remote startup command and
/// forked-workspace remote configuration, the actual split / new-tab / new-
/// workspace terminal creation, the post-create directory application and zoom
/// restoration, the menu fork-availability gate, the snapshot lookup (restored,
/// then the shared live-agent index), and the failure beep.
///
/// The app target's `Workspace` conforms and is injected via
/// ``AgentForkCoordinator/attach(host:)``. Every method mirrors one read or
/// mutation the legacy method bodies performed on `self`, so the move is
/// byte-faithful.
///
/// The associated types keep the seam free of the concrete app types so the
/// package graph stays acyclic (the workspace package depends on
/// `CMUXAgentLaunch`, never the reverse): `Snapshot` is the restorable-agent
/// snapshot, `ForkedTerminal` the created terminal panel the split / new-tab
/// forks return, `PaneIdentifier` / `TabIdentifier` the live bonsplit ids, and
/// `Direction` / `Destination` the app's split-direction / fork-destination
/// vocabulary. `RemoteConfiguration` is the shared `CmuxCore` Sendable value
/// type, read directly by the coordinator.
@MainActor
public protocol AgentForkHosting: AnyObject {
    /// The restorable-agent snapshot payload type (app target's
    /// `SessionRestorableAgentSnapshot`).
    associatedtype Snapshot

    /// The created terminal panel a split / new-tab fork returns (app target's
    /// `TerminalPanel`).
    associatedtype ForkedTerminal

    /// The live bonsplit pane identifier (app target's `PaneID`).
    associatedtype PaneIdentifier

    /// The live bonsplit tab identifier (app target's `TabID`).
    associatedtype TabIdentifier

    /// The split-direction vocabulary the split fork consumes (app target's
    /// `SplitDirection`).
    associatedtype Direction

    /// The fork-destination vocabulary the right-click dispatch consumes (app
    /// target's `AgentConversationForkDestination`).
    associatedtype Destination

    // MARK: - Panel classification

    /// Whether the panel currently maps to a live terminal panel (legacy
    /// `panels[panelId] is TerminalPanel`).
    func agentForkPanelIsTerminal(_ panelId: UUID) -> Bool

    // MARK: - Working directory / startup input

    /// The first non-empty resolved fork working directory for the panel, given
    /// the snapshot's own working directory, then the live panel directory, the
    /// terminal panel's requested working directory, and the workspace current
    /// directory (legacy `forkAgentWorkingDirectory(fromPanelId:snapshot:)`,
    /// which trims and first-non-empty-picks across those four candidates). The
    /// snapshot stays app-side so its `workingDirectory` field is read by the host.
    func agentForkWorkingDirectory(panelId: UUID, snapshot: Snapshot) -> String?

    /// The fork startup input for the snapshot once its working directory is set
    /// to `workingDirectory` (legacy: assign `launchSnapshot.workingDirectory`
    /// then `launchSnapshot.forkStartupInput(...allowLauncherScript:)`). The host
    /// owns the snapshot mutation and the `forkStartupInput` call so the
    /// app-target snapshot type and its `FileManager`/temp-dir defaults stay
    /// app-side.
    func agentForkStartupInput(
        snapshot: Snapshot,
        workingDirectory: String?,
        allowLauncherScript: Bool
    ) -> String?

    // MARK: - Remote fork resolution

    /// The remote terminal startup command for the panel, or `nil` for a local
    /// fork (legacy `forkAgentRemoteStartupCommand(fromPanelId:)`:
    /// `isRemoteTerminalSurface` guard then `remoteTerminalStartupCommand()`).
    func agentForkRemoteStartupCommand(panelId: UUID) -> String?

    /// The remote configuration to apply to a forked new workspace, or `nil` for
    /// a local fork (legacy
    /// `forkAgentRemoteConfigurationForNewWorkspace(fromPanelId:)`). The host
    /// owns the `remoteConfiguration` read, the forked-SSH-options derivation,
    /// the `sessionSnapshot(...).workspaceConfiguration(...)` round-trip, and the
    /// `TerminalController.shared` socket-path read.
    func agentForkRemoteConfigurationForNewWorkspace(
        panelId: UUID
    ) -> WorkspaceRemoteConfiguration?

    // MARK: - Snapshot lookup

    /// The snapshot used by the right-click fork path: the workspace's restored
    /// snapshot if present, else the shared live-agent index lookup, else the
    /// lazily process-detected snapshot (legacy `forkableAgentSnapshot(forPanelId:)`).
    func agentForkableSnapshot(panelId: UUID) -> Snapshot?

    /// Whether the snapshot is probe-free fork-supported for the panel, mirroring
    /// the menu-visibility gate exactly (legacy
    /// `ContentView.commandPaletteSnapshotForkAvailability(snapshot,
    /// isRemoteTerminal:) == .supportedWithoutProbe`). The remote classification
    /// and the availability computation stay app-side.
    func agentForkSnapshotIsSupportedWithoutProbe(
        snapshot: Snapshot,
        panelId: UUID
    ) -> Bool

    // MARK: - Split / new-tab / new-workspace creation

    /// Saves the current split-zoom pane id and clears the zoom if one is active,
    /// returning the saved id so the caller can restore it on failure (legacy
    /// `let zoomedPaneId = bonsplitController.zoomedPaneId; if … { clearSplitZoom() }`).
    func agentForkSaveAndClearSplitZoom() -> PaneIdentifier?

    /// Restores a previously zoomed pane after a failed fork (legacy
    /// `bonsplitController.togglePaneZoom(inPane: zoomedPaneId)`).
    func agentForkRestoreSplitZoom(_ paneId: PaneIdentifier)

    /// The live pane that owns the panel, or `nil` if none (legacy
    /// `paneId(forPanelId:)`).
    func agentForkPaneId(forPanelId panelId: UUID) -> PaneIdentifier?

    /// Creates a split terminal surface in the panel's pane with the resolved
    /// fork inputs (legacy `splitPaneWithNewTerminal(...)`). `workingDirectory`
    /// is `nil` on a remote fork (the directory is applied after connect).
    func agentForkSplitPaneWithNewTerminal(
        targetPane: PaneIdentifier,
        direction: Direction,
        workingDirectory: String?,
        initialInput: String,
        remoteStartupCommand: String?
    ) -> ForkedTerminal?

    /// Creates a sibling terminal tab immediately to the right of `anchorTabId`
    /// in `paneId` with the resolved fork inputs (legacy
    /// `insertionIndexToRight(of:inPane:)` + `newTerminalSurface(...)` +
    /// `reorderSurface(...)`). `workingDirectory` is `nil` on a remote fork.
    func agentForkNewTabSurface(
        anchorTabId: TabIdentifier,
        paneId: PaneIdentifier,
        workingDirectory: String?,
        initialInput: String
    ) -> ForkedTerminal?

    /// Applies the resolved fork working directory to a created remote-fork
    /// terminal surface (legacy `updatePanelDirectory(panelId: forkedPanel.id,
    /// directory: workingDirectory)`).
    func agentForkApplyDirectory(to surface: ForkedTerminal, directory: String)

    /// Creates a brand-new forked workspace from the resolved launch descriptor,
    /// applying its remote configuration and post-connect directory (legacy
    /// `forkAgentConversationToNewWorkspace`: `owningTabManager.addWorkspace(...)`,
    /// `configureRemoteConnection(...)`, and the post-connect
    /// `updatePanelDirectory`). Returns `false` when there is no owning tab
    /// manager.
    func agentForkOpenNewWorkspace(launch: AgentConversationForkWorkspaceLaunch) -> Bool

    // MARK: - Destination dispatch

    /// The split direction for a fork destination, or `nil` for the new-tab /
    /// new-workspace destinations (legacy `destination.splitDirection`).
    func agentForkSplitDirection(for destination: Destination) -> Direction?

    /// Whether the destination is the new-tab destination (legacy `case .newTab`).
    func agentForkDestinationIsNewTab(_ destination: Destination) -> Bool

    /// Whether the destination is the new-workspace destination (legacy
    /// `case .newWorkspace`).
    func agentForkDestinationIsNewWorkspace(_ destination: Destination) -> Bool

    /// Emits the failure beep used when a right-click fork cannot proceed (legacy
    /// `NSSound.beep()`).
    func agentForkBeep()
}
