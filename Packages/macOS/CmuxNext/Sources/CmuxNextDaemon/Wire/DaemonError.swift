import Foundation

public enum DaemonError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No live connection; wait for the next `.connected` event.
    case notConnected
    /// The socket closed while a request was pending.
    case connectionClosed(reason: String)
    /// The daemon announced `daemon-shutdown` before closing.
    case daemonShutdown
    case socketPathTooLong(String)
    case connectFailed(path: String, errno: Int32)
    /// The daemon answered `ok:false`. A `cmux.protocol/2` resource error
    /// also carries its `details` (any JSON) and `retryable` flag; a raw
    /// protocol error has neither.
    case command(cmd: String, message: String, code: String?, details: JSONValue? = nil, retryable: Bool? = nil)
    case malformedResponse(String)
    case wrongApp(String)
    case unsupportedProtocol(Int)
    case missingCapabilities([String])
    /// No bundled or override cmux-tui binary was found.
    case binaryNotFound(searched: [String])
    case launchFailed(String)
    case timedOut(String)
    /// A command that starts a terminal got no reply within the terminal
    /// start deadline. cmux-tui may still create the terminal.
    case terminalStartTimedOut(String)
    case invalidSessionName(String)
    /// A remote machine's endpoint waits for the user (an SSH key or host
    /// key to fix, cmux-tui to install): retrying on a timer cannot help,
    /// the next retry waits for an event (activation, wake, Reconnect).
    case endpointBlocked(String)
    /// `server ensure` found the session owner alive but still restoring its
    /// terminals after the daemon's restore bound (`server.restore_timeout`).
    /// Carries the daemon's message. Retrying waits for the same owner.
    case sessionRestoreTimedOut(String)

    public var description: String {
        switch self {
        case .notConnected: "not connected to cmux-tui"
        case .connectionClosed(let reason): "cmux-tui connection closed: \(reason)"
        case .daemonShutdown: "cmux-tui daemon shut down"
        case .socketPathTooLong(let path): "socket path exceeds sun_path: \(path)"
        case .connectFailed(let path, let code): "connect \(path) failed: \(String(cString: strerror(code)))"
        case .command(let cmd, let message, let code, _, _): "\(cmd) failed: \(message)\(code.map { " [\($0)]" } ?? "")"
        case .malformedResponse(let detail): "malformed cmux-tui response: \(detail)"
        case .wrongApp(let app): "socket is served by \(app), not cmux-tui"
        case .unsupportedProtocol(let version): "cmux-tui protocol \(version) is not supported (need 12)"
        case .missingCapabilities(let names): "cmux-tui lacks capabilities: \(names.joined(separator: ", "))"
        case .binaryNotFound(let searched): "cmux-tui binary not found (searched \(searched.joined(separator: ", ")))"
        case .launchFailed(let detail): "cmux-tui server ensure failed: \(detail)"
        case .timedOut(let what): "timed out: \(what)"
        case .terminalStartTimedOut(let what): "timed out: \(what); the terminal may still appear"
        case .invalidSessionName(let name): "invalid cmux-tui session name: \(name)"
        case .endpointBlocked(let reason): reason
        case .sessionRestoreTimedOut(let message): "cmux-tui session restore timed out: \(message)"
        }
    }
}

extension DaemonError {
    /// The handshake found an incompatible owner (another protocol, or a required capability
    /// missing) and handed it off to the bundled build (`DaemonLauncher.handOffIncompatible`):
    /// a retry reaches its successor, so this is a lost connection, never a refusal.
    public static let incompatibleOwnerHandedOff = DaemonError.connectionClosed(reason: "incompatible owner handed off to the bundled build")

    /// The reply missed its deadline (``timedOut(_:)``): the command may still apply, and one that sets an absolute
    /// value may be sent again quietly (`SidebarFoldPersist.resending`).
    public var isMissedDeadline: Bool {
        if case .timedOut = self { return true }
        return false
    }

    /// Whether `error` is a ``DaemonError`` whose reply missed its deadline (``isMissedDeadline``).
    public static func missedDeadline(_ error: any Error) -> Bool { (error as? DaemonError)?.isMissedDeadline == true }

    /// A lost or restarting connection (retry), as opposed to the daemon's own refusal.
    public var isLostConnection: Bool {
        switch self {
        case .notConnected, .connectionClosed, .daemonShutdown, .connectFailed, .timedOut: true
        default: false
        }
    }

    /// cmux-tui refused the connection at its connection limit (`server.busy`): it is
    /// alive and frees a slot when one of its connections ends, so a retry soon can work.
    public var isBusyRefusal: Bool {
        if case .connectionClosed(let reason) = self { return reason == LineTransport.busyRefusal }
        return false
    }

    /// The daemon has no workspace by the id a request named (`selector.not_found` for a workspace): it ended, or its
    /// create was undone, after the caller read it.
    public var isWorkspaceNotFound: Bool {
        guard case .command(_, _, let code?, let details, _) = self, code == "selector.not_found" else { return false }
        return details?["scope"]?.stringValue == "workspace"
    }
}

extension DaemonError {
    /// The remote entry's refusal of a command it never admits on this link (`remote_denied`):
    /// asking again gets the same answer, so callers stop instead of retrying.
    public static let remoteDeniedCode = "remote_denied"

    /// Whether the daemon refused this request as one its link never admits (``remoteDeniedCode``).
    public var isRemoteDenied: Bool {
        if case .command(_, _, let code, _, _) = self { return code == Self.remoteDeniedCode }
        return false
    }
}
