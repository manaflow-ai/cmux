public import Foundation
import CmuxCore

/// Orchestrates the agent-conversation fork flows for one workspace window.
///
/// This `@MainActor` coordinator is the lifted home of the fork orchestration
/// bodies the app-target `Workspace` god object kept inline next to its split /
/// terminal-surface machinery. It sequences the four user-visible fork paths
/// (split, new tab, new workspace, and the resolved new-workspace launch
/// descriptor), plus the right-click context-action dispatch and the menu
/// availability check. The live work each path needs (panel classification, the
/// resolved fork directory and startup input, the remote startup command and
/// forked-workspace remote configuration, the actual split / new-tab / new-
/// workspace terminal creation, zoom save/restore, the snapshot lookup, and the
/// failure beep) is reached through ``AgentForkHosting``, conformed by
/// `Workspace` and injected via ``attach(host:)``.
///
/// `Workspace` owns one instance and forwards each former method through a
/// one-line forward, so every external call site stays byte-identical.
///
/// `@MainActor` because every fork path originates on the main actor (a sidebar
/// / command-palette / context-menu user action driving the live bonsplit tree
/// and `TabManager`), so co-locating the orchestration with its callers keeps
/// the forwards plain calls with no bridging.
///
/// The coordinator reads the shared `CmuxCore` `WorkspaceRemoteConfiguration`
/// value type directly (for the local-vs-remote-fork branch and the descriptor
/// assembly) and reaches everything else through the host seam, so it never
/// imports the concrete app types and the package graph stays acyclic.
@MainActor
public final class AgentForkCoordinator<Host: AgentForkHosting> {
    /// The restorable-agent snapshot payload type, taken from the host.
    public typealias Snapshot = Host.Snapshot
    /// The created terminal panel type a split / new-tab fork returns.
    public typealias ForkedTerminal = Host.ForkedTerminal
    /// The live bonsplit pane identifier type.
    public typealias PaneIdentifier = Host.PaneIdentifier
    /// The live bonsplit tab identifier type.
    public typealias TabIdentifier = Host.TabIdentifier
    /// The split-direction vocabulary the split fork consumes.
    public typealias Direction = Host.Direction
    /// The fork-destination vocabulary the right-click dispatch consumes.
    public typealias Destination = Host.Destination

    private weak var host: Host?

    /// Creates a coordinator. Call ``attach(host:)`` at the composition point
    /// before any fork flow runs.
    public init() {}

    /// Injects the live-workspace seam. Set before any fork orchestration runs so
    /// the panel reads, terminal creation, and side effects reach the workspace.
    public func attach(host: Host) {
        self.host = host
    }

    // MARK: - New-workspace launch descriptor

    /// Resolves the launch descriptor for forking the panel's agent conversation
    /// into a brand-new workspace, or `nil` when the panel is not a terminal or
    /// no fork startup input is available. Faithful lift of
    /// `Workspace.forkAgentWorkspaceLaunch(fromPanelId:snapshot:fileManager:temporaryDirectory:)`;
    /// the host owns the snapshot mutation + `forkStartupInput` (which carry the
    /// app-target `FileManager`/temp-dir defaults), so this resolver takes no
    /// I/O parameters.
    public func forkAgentWorkspaceLaunch(
        fromPanelId panelId: UUID,
        snapshot: Snapshot
    ) -> AgentConversationForkWorkspaceLaunch? {
        guard let host else { return nil }
        let workingDirectory = host.agentForkWorkingDirectory(panelId: panelId, snapshot: snapshot)
        let remoteStartupCommand = host.agentForkRemoteStartupCommand(panelId: panelId)
        let remoteConfiguration = host.agentForkRemoteConfigurationForNewWorkspace(panelId: panelId)
        let isRemoteFork = remoteConfiguration?.terminalStartupCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard host.agentForkPanelIsTerminal(panelId),
              let startupInput = host.agentForkStartupInput(
                  snapshot: snapshot,
                  workingDirectory: workingDirectory,
                  allowLauncherScript: !isRemoteFork
              ) else {
            return nil
        }

        return AgentConversationForkWorkspaceLaunch(
            workingDirectory: workingDirectory,
            terminalWorkingDirectory: isRemoteFork ? nil : workingDirectory,
            initialTerminalCommand: remoteConfiguration?.terminalStartupCommand ?? remoteStartupCommand,
            initialTerminalInput: startupInput,
            initialTerminalEnvironment: isRemoteFork ? (remoteConfiguration?.sshTerminalStartupEnvironment ?? [:]) : [:],
            remoteConfiguration: remoteConfiguration,
            autoConnectRemoteConfiguration: remoteConfiguration != nil
        )
    }

    // MARK: - Split fork

    /// Forks the panel's agent conversation into a sibling split in the given
    /// direction, returning the created terminal surface or `nil`. Faithful lift
    /// of `Workspace.forkAgentConversation(fromPanelId:snapshot:direction:...)`.
    @discardableResult
    public func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: Snapshot,
        direction: Direction
    ) -> ForkedTerminal? {
        guard let host else { return nil }
        let workingDirectory = host.agentForkWorkingDirectory(panelId: panelId, snapshot: snapshot)
        let remoteStartupCommand = host.agentForkRemoteStartupCommand(panelId: panelId)
        guard host.agentForkPanelIsTerminal(panelId),
              let paneId = host.agentForkPaneId(forPanelId: panelId),
              let startupInput = host.agentForkStartupInput(
                  snapshot: snapshot,
                  workingDirectory: workingDirectory,
                  allowLauncherScript: remoteStartupCommand == nil
              ) else {
            return nil
        }

        let zoomedPaneId = host.agentForkSaveAndClearSplitZoom()
        let forkedPanel = host.agentForkSplitPaneWithNewTerminal(
            targetPane: paneId,
            direction: direction,
            workingDirectory: remoteStartupCommand == nil ? workingDirectory : nil,
            initialInput: startupInput,
            remoteStartupCommand: remoteStartupCommand
        )
        if let forkedPanel,
           remoteStartupCommand != nil,
           let workingDirectory {
            host.agentForkApplyDirectory(to: forkedPanel, directory: workingDirectory)
        }
        if forkedPanel == nil, let zoomedPaneId {
            host.agentForkRestoreSplitZoom(zoomedPaneId)
        }
        return forkedPanel
    }

    // MARK: - New-tab fork

    /// Forks the panel's agent conversation into a brand-new sibling tab placed
    /// immediately to the right of `anchorTabId` in `paneId`, returning the
    /// created terminal surface or `nil`. Faithful lift of
    /// `Workspace.forkAgentConversationToNewTab(fromPanelId:snapshot:anchorTabId:paneId:...)`.
    @discardableResult
    public func forkAgentConversationToNewTab(
        fromPanelId panelId: UUID,
        snapshot: Snapshot,
        anchorTabId: TabIdentifier,
        paneId: PaneIdentifier
    ) -> ForkedTerminal? {
        guard let host else { return nil }
        let workingDirectory = host.agentForkWorkingDirectory(panelId: panelId, snapshot: snapshot)
        let remoteStartupCommand = host.agentForkRemoteStartupCommand(panelId: panelId)
        guard host.agentForkPanelIsTerminal(panelId),
              let startupInput = host.agentForkStartupInput(
                  snapshot: snapshot,
                  workingDirectory: workingDirectory,
                  allowLauncherScript: remoteStartupCommand == nil
              ) else {
            return nil
        }

        let zoomedPaneId = host.agentForkSaveAndClearSplitZoom()
        let forkedPanel = host.agentForkNewTabSurface(
            anchorTabId: anchorTabId,
            paneId: paneId,
            workingDirectory: remoteStartupCommand == nil ? workingDirectory : nil,
            initialInput: startupInput
        )
        if let forkedPanel {
            if remoteStartupCommand != nil, let workingDirectory {
                host.agentForkApplyDirectory(to: forkedPanel, directory: workingDirectory)
            }
        } else if let zoomedPaneId {
            host.agentForkRestoreSplitZoom(zoomedPaneId)
        }
        return forkedPanel
    }

    // MARK: - New-workspace fork

    /// Forks the panel's agent conversation into a brand-new workspace, returning
    /// whether the workspace was opened. Faithful lift of
    /// `Workspace.forkAgentConversationToNewWorkspace(fromPanelId:snapshot:)`; the
    /// host owns the `addWorkspace` / `configureRemoteConnection` /
    /// post-connect-directory live work over the resolved launch descriptor.
    @discardableResult
    public func forkAgentConversationToNewWorkspace(
        fromPanelId panelId: UUID,
        snapshot: Snapshot
    ) -> Bool {
        guard let host,
              let launch = forkAgentWorkspaceLaunch(fromPanelId: panelId, snapshot: snapshot) else {
            return false
        }
        return host.agentForkOpenNewWorkspace(launch: launch)
    }

    // MARK: - Availability

    /// Whether the panel can be forked from the right-click context menu: it is a
    /// live terminal, a probe-free fork snapshot exists, and that snapshot is
    /// `.supportedWithoutProbe`. Faithful lift of
    /// `Workspace.canForkAgentConversationFromPanel(_:)`.
    public func canForkAgentConversationFromPanel(_ panelId: UUID) -> Bool {
        guard let host, host.agentForkPanelIsTerminal(panelId) else { return false }
        guard let snapshot = host.agentForkableSnapshot(panelId: panelId) else {
            return false
        }
        return host.agentForkSnapshotIsSupportedWithoutProbe(snapshot: snapshot, panelId: panelId)
    }

    // MARK: - Destination dispatch

    /// Handles a fork right-click context action: looks up the panel's fork
    /// snapshot, re-applies the menu-visibility gate, resolves the configured
    /// destination, and dispatches, beeping on any failure. Faithful lift of
    /// `Workspace.handleForkConversationContextAction(...)`; the caller resolves
    /// the panel id from the tab and supplies the resolved destination closure so
    /// the live tab/pane lookups stay app-side.
    public func handleForkConversationContextAction(
        panelId: UUID?,
        destination resolveDestination: () -> Destination,
        anchorTabId: TabIdentifier,
        paneId: PaneIdentifier
    ) {
        guard let host else { return }
        guard let panelId,
              let snapshot = host.agentForkableSnapshot(panelId: panelId) else {
            host.agentForkBeep()
            return
        }
        // Mirror the menu-visibility gate exactly: only fork when the snapshot is
        // probe-free supported. Using the weaker `!= .unsupported` here would let
        // a `.requiresProbe` snapshot through if the action is ever wired up
        // outside the bonsplit menu, leading to a fork that may quietly fail at
        // the shell.
        guard host.agentForkSnapshotIsSupportedWithoutProbe(snapshot: snapshot, panelId: panelId) else {
            host.agentForkBeep()
            return
        }

        let destination = resolveDestination()
        guard forkAgentConversation(
            fromPanelId: panelId,
            snapshot: snapshot,
            destination: destination,
            anchorTabId: anchorTabId,
            paneId: paneId
        ) else {
            host.agentForkBeep()
            return
        }
    }

    /// Dispatches a fork to the resolved destination, returning whether it
    /// proceeded. Faithful lift of the post-class
    /// `Workspace.forkAgentConversation(fromPanelId:snapshot:destination:anchorTabId:paneId:)`.
    @discardableResult
    public func forkAgentConversation(
        fromPanelId panelId: UUID,
        snapshot: Snapshot,
        destination: Destination,
        anchorTabId: TabIdentifier,
        paneId: PaneIdentifier
    ) -> Bool {
        guard let host else { return false }
        if let direction = host.agentForkSplitDirection(for: destination) {
            return forkAgentConversation(
                fromPanelId: panelId,
                snapshot: snapshot,
                direction: direction
            ) != nil
        }

        if host.agentForkDestinationIsNewTab(destination) {
            return forkAgentConversationToNewTab(
                fromPanelId: panelId,
                snapshot: snapshot,
                anchorTabId: anchorTabId,
                paneId: paneId
            ) != nil
        }
        if host.agentForkDestinationIsNewWorkspace(destination) {
            return forkAgentConversationToNewWorkspace(
                fromPanelId: panelId,
                snapshot: snapshot
            )
        }
        return false
    }
}
