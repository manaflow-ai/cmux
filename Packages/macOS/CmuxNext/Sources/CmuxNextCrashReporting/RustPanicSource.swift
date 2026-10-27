public import Foundation

/// Which cmux Rust process wrote a panic log, and how its panics are labeled in Sentry.
///
/// Every log has the `cmux-panic-log` line format (one JSON object per
/// panic: `message`, `location`, `thread`, `backtrace`, `test`, plus the
/// process's own fields). The source sets the `process` and `crash_source`
/// tags and the fingerprint prefix, so each process's panics group apart.
public struct RustPanicSource: Sendable, Equatable {
    /// The `process` tag, such as `cmux-tui` or `acpmux`.
    public var process: String
    /// The first fingerprint element; the panic's `file:line:col` follows it.
    public var fingerprintPrefix: String
    /// The `crash_source` tag.
    public var crashSource: String
    /// The text before the location in the event message, such as `cmux-tui owner panic`.
    public var label: String

    /// A source with every label given.
    /// - Parameters:
    ///   - process: The `process` tag.
    ///   - fingerprintPrefix: The first fingerprint element.
    ///   - crashSource: The `crash_source` tag.
    ///   - label: The text before the location in the event message.
    public init(process: String, fingerprintPrefix: String, crashSource: String, label: String) {
        self.process = process
        self.fingerprintPrefix = fingerprintPrefix
        self.crashSource = crashSource
        self.label = label
    }

    /// The app's cmux-tui session owner (`owner-panics-<session>.jsonl`).
    /// Its fingerprint prefix predates this type, so existing issues keep grouping.
    public static let owner = RustPanicSource(process: "cmux-tui", fingerprintPrefix: "owner-panic",
                                              crashSource: "owner_panic_log", label: "cmux-tui owner panic")
    /// The acpmux daemon (`$ACPMUX_HOME/panics.jsonl`).
    public static let acpmux = RustPanicSource(process: "acpmux", fingerprintPrefix: "acpmux-panic",
                                               crashSource: "acpmux_panic_log", label: "acpmux daemon panic")

    /// The owner's app hosts, `cmux-app-host` (`app-host-panics.jsonl` at the owner's state root).
    public static let appHost = RustPanicSource(process: "cmux-app-host", fingerprintPrefix: "app-host-panic",
                                                crashSource: "app_host_panic_log", label: "cmux-app-host panic")
    /// The owner's browser host, `cmux-browser-host serve` (`browser-host-panics.jsonl` at the owner's state root).
    public static let browserHost = RustPanicSource(process: "cmux-browser-host", fingerprintPrefix: "browser-host-panic",
                                                    crashSource: "browser_host_panic_log",
                                                    label: "cmux-browser-host panic")
    /// The acpmux daemon's agent hosts, `acpmux __agent-host` (`$ACPMUX_HOME/agent-host-panics.jsonl`).
    public static let agentHost = RustPanicSource(process: "acpmux-agent-host", fingerprintPrefix: "agent-host-panic",
                                                  crashSource: "agent_host_panic_log", label: "acpmux agent host panic")
    /// `cmux mcp serve` (`mcp-panics.jsonl` at the owner's state root).
    public static let mcp = RustPanicSource(process: "cmux-mcp", fingerprintPrefix: "mcp-panic",
                                            crashSource: "mcp_panic_log", label: "cmux mcp serve panic")

    /// The acpmux daemon's panic log under its home (`ACPMUX_HOME`).
    /// - Parameter acpmuxHome: The daemon's `ACPMUX_HOME`.
    /// - Returns: `<acpmuxHome>/panics.jsonl`.
    public static func acpmuxLog(acpmuxHome: URL) -> URL {
        acpmuxHome.appending(path: "panics.jsonl")
    }

    /// The agent hosts' panic log under the acpmux home (acpmux `agent_host::panic_log_path`).
    /// - Parameter acpmuxHome: The daemon's `ACPMUX_HOME`.
    /// - Returns: `<acpmuxHome>/agent-host-panics.jsonl`.
    public static func agentHostLog(acpmuxHome: URL) -> URL {
        acpmuxHome.appending(path: "agent-host-panics.jsonl")
    }

    /// The panic log of a process the owner's machine runs beside the owner
    /// (cmux-tui-core `HelperPanicLog`): ``appHost``, ``browserHost`` or ``mcp``.
    /// - Parameter stateRoot: The owner's state root (the parent of its sessions directory).
    /// - Returns: The log's URL, or nil for a source whose log is elsewhere.
    public func helperLog(stateRoot: URL) -> URL? {
        let name: String? = switch self {
        case .appHost: "app-host-panics.jsonl"
        case .browserHost: "browser-host-panics.jsonl"
        case .mcp: "mcp-panics.jsonl"
        default: nil
        }
        return name.map { stateRoot.appending(path: $0) }
    }

    /// Every helper process's panic log: the owner's app hosts, browser host and `cmux mcp serve` at
    /// its state root, and acpmux's agent hosts under the acpmux home when there is one.
    /// - Parameters:
    ///   - stateRoot: The owner's state root.
    ///   - acpmuxHome: The acpmux daemon's home, or nil with no acpmux.
    /// - Returns: Each source with its log.
    public static func helperLogs(stateRoot: URL, acpmuxHome: URL?) -> [(RustPanicSource, URL)] {
        var logs = [RustPanicSource.appHost, .browserHost, .mcp].compactMap { source in
            source.helperLog(stateRoot: stateRoot).map { (source, $0) }
        }
        if let acpmuxHome { logs.append((.agentHost, agentHostLog(acpmuxHome: acpmuxHome))) }
        return logs
    }
}
