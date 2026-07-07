public import Foundation
public import CmuxCore

/// The directory-and-remote-state projection of the window's selected
/// workspace, as observed by ``SelectedWorkspaceDirectoryModel``.
///
/// This is the lift of the private `Snapshot` struct that
/// `SelectedWorkspaceDirectoryObserver` kept inside `ContentView.swift`. It is
/// the unit of change the model deduplicates on: the model bumps its
/// ``SelectedWorkspaceDirectoryModel/directoryChangeGeneration`` exactly when a
/// new distinct snapshot arrives, matching the legacy Combine
/// `removeDuplicates()` semantics one-for-one. All fields are value types
/// already owned by `CmuxCore`, so the snapshot is `Sendable` and can cross the
/// ``SelectedWorkspaceReading`` `AsyncStream` boundary.
///
/// A snapshot with `workspaceId == nil` and every other field `nil` is the
/// "no selection" snapshot the legacy pipeline emitted through `Just(...)` when
/// the selected workspace resolved to `nil`.
public struct SelectedWorkspaceDirectorySnapshot: Equatable, Sendable {
    /// The selected workspace's id, or `nil` when nothing is selected.
    public let workspaceId: UUID?
    /// The selected workspace's local current directory (legacy
    /// `Workspace.currentDirectory`).
    public let currentDirectory: String?
    /// The selected workspace's remote configuration, if any (legacy
    /// `Workspace.remoteConfiguration`).
    public let remoteConfiguration: WorkspaceRemoteConfiguration?
    /// The selected workspace's remote connection state (legacy
    /// `Workspace.remoteConnectionState`).
    public let remoteConnectionState: WorkspaceRemoteConnectionState?
    /// The selected workspace's remote connection detail string, if any
    /// (legacy `Workspace.remoteConnectionDetail`).
    public let remoteConnectionDetail: String?
    /// The selected workspace's remote daemon status, if any (legacy
    /// `Workspace.remoteDaemonStatus`).
    public let remoteDaemonStatus: WorkspaceRemoteDaemonStatus?
    /// Number of active remote terminal sessions in the selected workspace
    /// (legacy `Workspace.activeRemoteTerminalSessionCount`).
    public let activeRemoteTerminalSessionCount: Int

    /// Creates a snapshot. Pass all-`nil` for the "no selection" snapshot.
    public init(
        workspaceId: UUID?,
        currentDirectory: String?,
        remoteConfiguration: WorkspaceRemoteConfiguration?,
        remoteConnectionState: WorkspaceRemoteConnectionState?,
        remoteConnectionDetail: String?,
        remoteDaemonStatus: WorkspaceRemoteDaemonStatus?,
        activeRemoteTerminalSessionCount: Int
    ) {
        self.workspaceId = workspaceId
        self.currentDirectory = currentDirectory
        self.remoteConfiguration = remoteConfiguration
        self.remoteConnectionState = remoteConnectionState
        self.remoteConnectionDetail = remoteConnectionDetail
        self.remoteDaemonStatus = remoteDaemonStatus
        self.activeRemoteTerminalSessionCount = activeRemoteTerminalSessionCount
    }

    /// The "no selection" snapshot: every field `nil`. Matches the legacy
    /// `Just(Snapshot(workspaceId: nil, …))` branch.
    public static let none = SelectedWorkspaceDirectorySnapshot(
        workspaceId: nil,
        currentDirectory: nil,
        remoteConfiguration: nil,
        remoteConnectionState: nil,
        remoteConnectionDetail: nil,
        remoteDaemonStatus: nil,
        activeRemoteTerminalSessionCount: 0
    )
}
