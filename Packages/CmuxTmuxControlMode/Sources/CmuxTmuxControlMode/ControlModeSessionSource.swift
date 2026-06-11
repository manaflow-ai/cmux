import Foundation

/// What a control-mode terminal renderer needs from whatever owns the
/// authoritative session (local tmux today; the Mac mobile host and
/// cmuxd-remote later). The renderer is always a manual-IO Ghostty surface;
/// the source differs only in transport. See
/// `plans/feat-control-mode-terminals/DESIGN.md` in cmuxterm-hq.
public protocol ControlModeSessionSource: AnyObject, Sendable {
    /// Human-readable name for the session (used for the surface title).
    var displayName: String { get }

    /// Begin the session at the given size. Delegate callbacks deliver the
    /// initial snapshot, then live output, then end-of-session. Callbacks may
    /// be invoked on a background queue; the caller is responsible for hopping
    /// to the main actor before touching UI.
    func start(initialSize: TerminalSize, delegate: any ControlModeSessionDelegate)

    /// Forward bytes the user typed (already encoded by the local surface).
    func sendInput(_ bytes: [UInt8])

    /// Notify the source the local surface resized.
    func resize(_ size: TerminalSize)

    /// Tear the session down (detach; does not kill the server-side session).
    func stop()
}

/// Callbacks from a ``ControlModeSessionSource``.
public protocol ControlModeSessionDelegate: AnyObject, Sendable {
    /// The initial screen + scrollback snapshot, as bytes to feed into the
    /// local surface before any live output.
    func controlModeSession(didProduceSnapshot bytes: [UInt8])
    /// Live bytes from the attached pane.
    func controlModeSession(didProduceOutput bytes: [UInt8])
    /// The session ended (detach, exit, or gateway death). `reason` is a
    /// best-effort human-readable cause.
    func controlModeSession(didEndWithReason reason: String?)
}

/// What to attach to when starting a local tmux control-mode session.
public enum TmuxAttachTarget: Equatable, Sendable {
    /// Attach the most-recently-used session; fail if none exists.
    case mostRecent
    /// Attach the named session, creating it if it does not exist
    /// (`new-session -A -s <name>`).
    case session(String)

    /// The argument vector for `tmux` (after the `-CC` flag) for this target.
    public var tmuxArguments: [String] {
        switch self {
        case .mostRecent:
            return ["attach"]
        case let .session(name):
            return ["new-session", "-A", "-s", name]
        }
    }
}
