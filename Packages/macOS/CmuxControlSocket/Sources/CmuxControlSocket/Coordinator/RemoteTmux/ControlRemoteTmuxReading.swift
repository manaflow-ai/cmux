/// The seam through which ``ControlRemoteTmuxWorker`` reaches the live remote-tmux
/// controller to serve the worker-lane `remote.tmux.*` control commands, without
/// the package importing the app target.
///
/// ## Why the seam
///
/// The `remote.tmux.*` bodies drive `AppDelegate.shared?.remoteTmuxController`
/// (an app-target `RemoteTmuxController`) and read the live beta-feature flag —
/// neither of which this package may import. This seam inverts that: the package
/// owns the protocol, the app conforms it over the controller, mapping the
/// controller's app-side value types into the package's Sendable transfer twins
/// (``ControlRemoteTmuxSession`` / ``ControlRemoteTmuxAttachOutcome`` /
/// ``ControlRemoteTmuxStateSnapshot``).
///
/// ## Isolation delta (deliberate, documented)
///
/// The legacy bodies ran on the nonisolated socket-worker thread inside
/// `v2VmCall` and fetched the controller with `MainActor.run(body:)` (then ran
/// its `async` methods, themselves main-actor isolated). This seam replaces that
/// per-body main hop with an `async` surface: each member awaits the app
/// conformer, which hops to the main actor internally to read
/// `remoteTmuxController` and call its methods. The worker
/// (``ControlRemoteTmuxWorker``) is therefore `async`; the single remaining
/// worker-thread→async bridge lives in the app's worker-lane dispatcher. The
/// per-command timeout and the `vm_error` / success wire shapes are preserved by
/// the worker, so payloads are byte-identical (a thrown error renders the same
/// `vm_error` + `String(describing:)` body the legacy `v2VmCall` produced).
///
/// `Sendable` (not `@MainActor`) so the worker can hold it across the
/// worker-thread boundary; the app conformer hops to the main actor internally.
public protocol ControlRemoteTmuxReading: Sendable {
    /// Whether the remote-tmux beta feature is enabled (the legacy
    /// `RemoteTmuxController.isEnabled` UserDefaults read). Checked synchronously
    /// at the top of every command, exactly as the legacy bodies gated.
    func isEnabled() -> Bool

    /// Discovers the tmux sessions on a host (`remote.tmux.sessions`), or throws
    /// when the host is unreachable / the app is not ready. Matches
    /// `controller.listSessions(host:)`.
    ///
    /// - Parameter host: The validated remote host.
    /// - Returns: The discovered sessions.
    func listSessions(host: ControlRemoteTmuxHost) async throws -> [ControlRemoteTmuxSession]

    /// Attaches a `tmux -CC` control client to a session (`remote.tmux.attach`),
    /// returning the interactive `ssh` argv when the host needs authentication
    /// first, or `nil` once attached. Matches
    /// `controller.attachControlStreamWhenReady(host:sessionName:createIfMissing:)`.
    ///
    /// - Parameters:
    ///   - host: The validated remote host.
    ///   - sessionName: The tmux session name.
    ///   - createIfMissing: Attach-or-create when `true`.
    /// - Returns: The `ssh` argv to authenticate, or `nil` when attached.
    func attachControlStreamWhenReady(
        host: ControlRemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool
    ) async throws -> [String]?

    /// Mirrors every tmux session on a host as its own sidebar workspace
    /// (`remote.tmux.mirror`). Matches `controller.mirrorHost(host:)`.
    ///
    /// - Parameter host: The validated remote host.
    func mirrorHost(host: ControlRemoteTmuxHost) async throws

    /// Opens (or reuses) a dedicated cmux window mirroring every tmux session on
    /// a host (`remote.tmux.window`). Matches
    /// `controller.mirrorHostInNewWindow(host:activateWindow:)`.
    ///
    /// - Parameters:
    ///   - host: The validated remote host.
    ///   - activateWindow: Whether to activate/focus the window.
    /// - Returns: The mirror/auth outcome.
    func mirrorHostInNewWindow(
        host: ControlRemoteTmuxHost,
        activateWindow: Bool
    ) async throws -> ControlRemoteTmuxAttachOutcome

    /// Detaches a control client, leaving the remote session alive
    /// (`remote.tmux.detach`), or throws when the app is not ready. Matches the
    /// legacy `controller.detach(host:sessionName:)` inside the `MainActor.run`
    /// that threw `unreachable("app not ready")` for a missing controller.
    ///
    /// - Parameters:
    ///   - host: The validated remote host.
    ///   - sessionName: The tmux session name.
    func detach(host: ControlRemoteTmuxHost, sessionName: String) async throws

    /// Reads a control client's observed state (`remote.tmux.state`), or `nil`
    /// when no connection exists for the host/session (the legacy
    /// `attached:false` fallback). Matches
    /// `controller.connection(host:sessionName:)?.snapshot()`.
    ///
    /// - Parameters:
    ///   - host: The validated remote host.
    ///   - sessionName: The tmux session name.
    /// - Returns: The state snapshot, or `nil` when not connected.
    func stateSnapshot(
        host: ControlRemoteTmuxHost,
        sessionName: String
    ) async -> ControlRemoteTmuxStateSnapshot?

    /// Reads per-window sizing diagnostics for a mirrored session
    /// (`remote.tmux.pane_grids`), or `nil` when no mirror exists for the
    /// host/session.
    ///
    /// - Parameters:
    ///   - host: The validated remote host.
    ///   - sessionName: The tmux session name.
    /// - Returns: Sizing snapshots for mirrored windows, or `nil` when not mirrored.
    func sizingSnapshots(
        host: ControlRemoteTmuxHost,
        sessionName: String
    ) async -> [ControlRemoteTmuxSizingSnapshot]?
}
