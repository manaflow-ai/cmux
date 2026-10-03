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
        }
    }
}
