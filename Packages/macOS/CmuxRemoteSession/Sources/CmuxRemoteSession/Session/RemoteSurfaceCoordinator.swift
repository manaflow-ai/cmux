internal import CmuxCore
public import CmuxRemoteWorkspace
public import Foundation

/// Per-workspace orchestrator for the *surface* side of a remote connection:
/// the remote-PTY bridge command entry points, remote port-scan kick/sync/
/// enablement, dropped-file upload, and the child-exit surface-tracking
/// predicates the close path consults.
///
/// This is the workspace-facing counterpart to ``RemoteSessionCoordinator``
/// (which owns the SSH/daemon/PTY lifecycle). Where the session coordinator
/// publishes connection state back through ``RemoteSessionHosting``, this
/// coordinator *reads* the small slice of live per-surface workspace state it
/// needs through ``RemoteSurfaceHosting`` and forwards command work to the
/// active session coordinator the host exposes.
///
/// ## Isolation design
///
/// This type is `@MainActor`, matching the legacy isolation exactly: every
/// `Workspace` method lifted here was a plain method on the `@MainActor`
/// `Workspace` class, so every read of live workspace state and every command
/// dispatch already ran on the main actor.
///
/// - The PTY command methods (`listRemotePTYSessions`, `closeRemotePTYSession`,
///   `startRemotePTYBridge`, `resizeRemotePTY`, `detachRemotePTYAttachment`)
///   resolve the active ``RemoteSessionCoordinator`` on the main actor and then
///   forward synchronously into it; that coordinator owns the queue confinement
///   and blocks the calling (main) thread for the result exactly as the legacy
///   `Workspace` methods did. The work that runs off-main lives in
///   ``RemoteSessionCoordinator``, not here.
/// - The surface-tracking predicates and the port-scan kicks read the host's
///   main-isolated surface sets and configuration directly.
/// - `uploadDroppedFiles` forwards to the session coordinator, which pins the
///   legacy main-queue completion contract.
///
/// The host reference is weak (the workspace owns the coordinator), so there is
/// no retain cycle.
@MainActor
public final class RemoteSurfaceCoordinator<Host: RemoteSurfaceHosting> {
    private weak var host: Host?

    /// Creates a surface coordinator. Call ``attach(host:)`` at the composition
    /// point before any command or predicate runs so the live-workspace reads
    /// and forwards resolve.
    public init() {}

    /// Injects the live-workspace seam. Set before any orchestration runs.
    public func attach(host: Host) {
        self.host = host
    }

    // MARK: - Surface-tracking predicates

    /// True when `panelId` is currently tracked as an active remote terminal
    /// surface. Faithful lift of `Workspace.isRemoteTerminalSurface(_:)`.
    public func isRemoteTerminalSurface(_ panelId: UUID) -> Bool {
        host?.hostActiveRemoteTerminalSurfaceIds.contains(panelId) ?? false
    }

    /// Marks the remote terminal session as ended when `surfaceId` is the last
    /// tracked active remote surface and no detach close transaction is in
    /// flight. SSH transports reclaim the relay port; all others pass `nil`.
    /// Faithful lift of `Workspace.markRemoteTerminalSessionClosingIfLast(surfaceId:)`.
    public func markRemoteTerminalSessionClosingIfLast(surfaceId: UUID) {
        guard let host else { return }
        guard !host.hostIsDetachingCloseTransaction,
              host.hostActiveRemoteTerminalSurfaceIds.count == 1,
              host.hostActiveRemoteTerminalSurfaceIds.contains(surfaceId) else {
            return
        }
        let relayPort: Int?
        if host.hostRemoteConfiguration?.transport == .ssh {
            relayPort = host.hostRemoteConfiguration?.relayPort
        } else {
            relayPort = nil
        }
        host.hostMarkRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: relayPort)
    }

    /// True when a persistent remote surface (preserve-after-exit) should stay
    /// open after its child terminal exits. Faithful lift of
    /// `Workspace.shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(_:)`.
    public func shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(_ panelId: UUID) -> Bool {
        guard let host else { return false }
        guard host.hostRemoteConfiguration?.preserveAfterTerminalExit == true else { return false }
        return host.hostActiveRemoteTerminalSurfaceIds.contains(panelId) ||
            host.hostEndedPersistentRemotePTYAttachSurfaceIds.contains(panelId)
    }

    /// True when the workspace should be demoted after a child exit, i.e. it is
    /// a remote workspace or the surface is pending a child-exit demotion.
    /// Faithful lift of `Workspace.shouldDemoteWorkspaceAfterChildExit(surfaceId:)`.
    public func shouldDemoteWorkspaceAfterChildExit(surfaceId: UUID) -> Bool {
        guard let host else { return false }
        return host.hostIsRemoteWorkspace ||
            host.hostPendingRemoteTerminalChildExitSurfaceIds.contains(surfaceId)
    }

    // MARK: - Dropped-file upload

    /// Uploads dropped files to the remote host for the active session, or fails
    /// with ``RemoteDropUploadError/unavailable`` when no session is active.
    /// Faithful lift of `Workspace.uploadDroppedFilesForRemoteTerminal(_:operation:completion:)`.
    ///
    /// The session coordinator pins the legacy contract of invoking the
    /// completion on the main queue, so the non-`Sendable` completion never runs
    /// off the caller's main thread even though the coordinator parameter is
    /// `@Sendable`.
    public func uploadDroppedFiles(
        _ fileURLs: [URL],
        operation: any RemoteTransferCancelling,
        completion: @escaping (Result<[String], any Error>) -> Void
    ) {
        guard let controller = host?.activeRemoteSessionCoordinator else {
            completion(.failure(RemoteDropUploadError.unavailable))
            return
        }
        nonisolated(unsafe) let completion = completion
        controller.uploadDroppedFiles(fileURLs, operation: operation) { result in
            completion(result)
        }
    }

    // MARK: - Port scanning

    /// Pushes the current per-surface TTY names to the active session so its
    /// port scan targets the right controlling terminals. No-op for non-remote
    /// workspaces. Faithful lift of `Workspace.syncRemotePortScanTTYs()`.
    public func syncRemotePortScanTTYs() {
        guard let host, host.hostIsRemoteWorkspace else { return }
        host.activeRemoteSessionCoordinator?.updateRemotePortScanTTYs(host.hostSurfaceTTYNames)
    }

    /// The active session coordinator, used by socket command handlers that
    /// resolve the remote PTY controller directly. Faithful lift of
    /// `Workspace.remotePTYSessionControllerForSocketCommand()`.
    public func remotePTYSessionControllerForSocketCommand() -> RemoteSessionCoordinator? {
        host?.activeRemoteSessionCoordinator
    }

    /// Syncs TTY names then triggers a remote port scan for `panelId`. No-op for
    /// non-remote workspaces. Faithful lift of
    /// `Workspace.kickRemotePortScan(panelId:reason:)`.
    public func kickRemotePortScan(panelId: UUID, reason: PortScanKickReason = .command) {
        guard let host, host.hostIsRemoteWorkspace else { return }
        syncRemotePortScanTTYs()
        host.activeRemoteSessionCoordinator?.kickRemotePortScan(panelId: panelId, reason: reason)
    }

    /// Pushes the remote port-scanning enablement to the active session, if any.
    /// No-op for non-remote workspaces. Faithful lift of
    /// `Workspace.applyRemotePortScanningEnabled(_:)`.
    public func applyRemotePortScanningEnabled(_ enabled: Bool) {
        host?.activeRemoteSessionCoordinator?.updateRemotePortScanningEnabled(enabled)
    }

    // MARK: - Remote PTY bridge commands

    /// Lists the remote persistent PTY sessions, or throws when the remote
    /// connection is not active. Faithful lift of
    /// `Workspace.listRemotePTYSessions()`.
    public func listRemotePTYSessions() throws -> [[String: Any]] {
        guard let controller = host?.activeRemoteSessionCoordinator else {
            throw NSError(domain: "cmux.remote.pty", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        return try controller.listPTYSessions()
    }

    /// Closes a remote persistent PTY session, or throws when the remote
    /// connection is not active. Faithful lift of
    /// `Workspace.closeRemotePTYSession(sessionID:)`.
    public func closeRemotePTYSession(sessionID: String) throws {
        guard let controller = host?.activeRemoteSessionCoordinator else {
            throw NSError(domain: "cmux.remote.pty", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.closePTYSession(sessionID: sessionID)
    }

    /// Starts (or attaches) a remote PTY bridge, or throws when the remote
    /// connection is not active. Faithful lift of
    /// `Workspace.startRemotePTYBridge(sessionID:attachmentID:command:requireExisting:)`.
    public func startRemotePTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool
    ) throws -> RemotePTYBridgeServer.Endpoint {
        guard let controller = host?.activeRemoteSessionCoordinator else {
            throw NSError(domain: "cmux.remote.pty", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        return try controller.startPTYBridge(
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting
        )
    }

    /// Resizes a remote PTY attachment, or throws when the remote connection is
    /// not active. Faithful lift of
    /// `Workspace.resizeRemotePTY(sessionID:attachmentID:attachmentToken:cols:rows:)`.
    public func resizeRemotePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws {
        guard let controller = host?.activeRemoteSessionCoordinator else {
            throw NSError(domain: "cmux.remote.pty", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.resizePTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken,
            cols: cols,
            rows: rows
        )
    }

    /// Detaches a remote PTY attachment, or throws when the remote connection is
    /// not active. Faithful lift of
    /// `Workspace.detachRemotePTYAttachment(sessionID:attachmentID:attachmentToken:)`.
    public func detachRemotePTYAttachment(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String
    ) throws {
        guard let controller = host?.activeRemoteSessionCoordinator else {
            throw NSError(domain: "cmux.remote.pty", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "remote connection is not active",
            ])
        }
        try controller.detachPTYSession(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }
}
