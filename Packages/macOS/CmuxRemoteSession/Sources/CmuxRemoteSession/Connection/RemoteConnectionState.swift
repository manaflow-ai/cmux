public import CmuxCore
public import Combine
public import Foundation
import Observation

/// The per-workspace remote *connection-lifecycle* state model.
///
/// This owns the published connection-lifecycle storage the legacy `Workspace`
/// god object kept as loose stored properties: the live remote configuration,
/// the connection-state machine value, the daemon status, the detected/
/// forwarded/conflicting remote ports, the shared proxy endpoint, the daemon
/// heartbeat, the active remote-terminal session count, the error-dedupe
/// fingerprints, the pending foreground-auth token, the pending disconnect
/// replacement, the disconnect-placeholder panel ids, and the active session
/// coordinator (plus its identity).
///
/// `Workspace` forwards each former stored property to a member of this model
/// (the established `WorkspaceSidebarMetadataModel` / `RemoteSurfaceTrackingState`
/// forwarding pattern), so external readers stay byte-identical.
///
/// ## Observer parity
///
/// Five of the legacy stored properties were bridged to Combine
/// `CurrentValueSubject`s consumed by other parts of the app (the sidebar
/// observation pipeline and the selected-workspace directory adapter). Those
/// subjects move here and are fed at `didSet` time exactly as before, preserving
/// the replay-on-subscribe and fires-on-equal-assignment contract the legacy
/// `@Published`-style bridges had.
///
/// ## Isolation design
///
/// `@MainActor`: every mutator and reader of this state ran on the main actor
/// inside the `@MainActor` `Workspace` class, and the SwiftUI views that read
/// the forwarded properties observe on the main actor. Marking the model
/// `@Observable` lets those view reads invalidate on change without the legacy
/// `objectWillChange` plumbing.
@MainActor
@Observable
public final class RemoteConnectionState {
    // MARK: - Combine observer-parity bridges
    //
    // `@ObservationIgnored`: these are Combine relays for non-SwiftUI consumers,
    // not Observation-tracked state. The Observation tracking lives on the
    // stored properties below; the subjects are fed from their `didSet`.

    /// Replays the live remote configuration to the sidebar observation pipeline.
    @ObservationIgnored
    public let remoteConfigurationPublisher = CurrentValueSubject<WorkspaceRemoteConfiguration?, Never>(nil)
    /// Replays the connection-state machine value.
    @ObservationIgnored
    public let remoteConnectionStatePublisher = CurrentValueSubject<WorkspaceRemoteConnectionState, Never>(.disconnected)
    /// Replays the connection detail string.
    @ObservationIgnored
    public let remoteConnectionDetailPublisher = CurrentValueSubject<String?, Never>(nil)
    /// Replays the daemon status snapshot.
    @ObservationIgnored
    public let remoteDaemonStatusPublisher = CurrentValueSubject<WorkspaceRemoteDaemonStatus, Never>(WorkspaceRemoteDaemonStatus())
    /// Replays the active remote-terminal session count.
    @ObservationIgnored
    public let activeRemoteTerminalSessionCountPublisher = CurrentValueSubject<Int, Never>(0)

    // MARK: - Published connection-lifecycle storage

    /// The live remote connection configuration, or `nil` for a local workspace.
    public var remoteConfiguration: WorkspaceRemoteConfiguration? {
        didSet { remoteConfigurationPublisher.send(remoteConfiguration) }
    }
    /// The remote connection-state machine value.
    public var remoteConnectionState: WorkspaceRemoteConnectionState = .disconnected {
        didSet { remoteConnectionStatePublisher.send(remoteConnectionState) }
    }
    /// The latest human-readable connection detail string.
    public var remoteConnectionDetail: String? {
        didSet { remoteConnectionDetailPublisher.send(remoteConnectionDetail) }
    }
    /// The latest cmuxd-remote daemon status snapshot.
    public var remoteDaemonStatus: WorkspaceRemoteDaemonStatus = WorkspaceRemoteDaemonStatus() {
        didSet { remoteDaemonStatusPublisher.send(remoteDaemonStatus) }
    }
    /// Remote listening ports detected across tracked surfaces.
    public var remoteDetectedPorts: [Int] = []
    /// Remote ports currently forwarded to the local proxy.
    public var remoteForwardedPorts: [Int] = []
    /// Remote ports that collided while forwarding.
    public var remotePortConflicts: [Int] = []
    /// The shared local proxy endpoint for the remote workspace, if any.
    public var remoteProxyEndpoint: BrowserProxyEndpoint?
    /// Monotonic daemon-heartbeat count.
    public var remoteHeartbeatCount: Int = 0
    /// Timestamp of the last observed daemon heartbeat.
    public var remoteLastHeartbeatAt: Date?
    /// Number of live remote-terminal SSH sessions in this workspace. Written
    /// both by the coordinator (disconnect resets to 0) and by the workspace's
    /// surface-tracking methods (which fuse this count with surface-set changes
    /// and stay app-side), so it is fully settable.
    public var activeRemoteTerminalSessionCount: Int = 0 {
        didSet { activeRemoteTerminalSessionCountPublisher.send(activeRemoteTerminalSessionCount) }
    }

    /// The active SSH/daemon session coordinator for the current attempt, or
    /// `nil` when disconnected. Owned here; the workspace exposes it (read-only)
    /// for the lifted remote-PTY/port-scan/upload commands.
    public var remoteSessionController: RemoteSessionCoordinator?
    /// The identity of ``remoteSessionController``, used by the publish adapter
    /// to drop stale publishes from a replaced coordinator.
    public var activeRemoteSessionControllerID: UUID?

    // MARK: - Internal dedupe / pending state
    //
    // Internal (not private) so the coordinator's same-module bodies can reach
    // them; nothing outside the package touches these.

    var pendingRemoteForegroundAuthToken: String?
    var remoteLastErrorFingerprint: String?
    var remoteLastDaemonErrorFingerprint: String?
    var remoteLastPortConflictFingerprint: String?
    /// The pending disconnect-replacement record. `public` because the app
    /// target's `Workspace` reads/clears it while building the replacement
    /// terminal (the disconnect-replacement scripting stays app-side).
    public var pendingRemoteDisconnectReplacement: PendingRemoteDisconnectReplacement?

    /// Panel ids currently showing a remote-disconnect placeholder terminal.
    public var remoteDisconnectPlaceholderPanelIds: Set<UUID> = []

    /// Creates an empty (disconnected, local) connection state.
    public init() {}

    /// Re-emits the current value of every observer-parity bridge so a fresh
    /// subscriber replays the present state, matching the legacy
    /// `@Published`-on-subscribe contract that `Workspace.init` reproduced.
    public func seedObserverParityBridges() {
        remoteConfigurationPublisher.send(remoteConfiguration)
        remoteConnectionStatePublisher.send(remoteConnectionState)
        remoteConnectionDetailPublisher.send(remoteConnectionDetail)
        remoteDaemonStatusPublisher.send(remoteDaemonStatus)
        activeRemoteTerminalSessionCountPublisher.send(activeRemoteTerminalSessionCount)
    }
}

/// Display target and reconnect command for the remote terminal that just
/// disconnected. Set right before the workspace creates a replacement terminal
/// so the replacement stays visibly disconnected instead of falling through to
/// a local login shell.
public struct PendingRemoteDisconnectReplacement: Sendable, Equatable {
    /// The display target of the disconnected remote.
    public let target: String
    /// The original reconnect command, if one was configured.
    public let reconnectCommand: String?

    /// Creates a pending-disconnect-replacement record.
    public init(target: String, reconnectCommand: String?) {
        self.target = target
        self.reconnectCommand = reconnectCommand
    }
}
