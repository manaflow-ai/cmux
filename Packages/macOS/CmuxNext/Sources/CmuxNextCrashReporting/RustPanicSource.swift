public import CmuxNextTrace
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
    /// A terminal host (`cmux-tui-host`). Its own panic log is `terminal-host-panics-<pid>.jsonl`; its owner also
    /// appends the host's `.crash` sidecar to the owner's log as one line with `"source": "cmux-tui-host"` before
    /// it deletes the sidecar (cmux-tui-core `host_crash.rs`), and that line is labeled as this source.
    public static let terminalHost = RustPanicSource(process: "cmux-tui-host", fingerprintPrefix: "terminal-host-panic",
                                                     crashSource: "terminal_host_panic_log", label: "cmux-tui-host panic")
    /// The `source` field of a terminal host's line in the owner's log.
    public static let terminalHostLineSource = "cmux-tui-host"

    /// The source that labels one line of the log this source reads: a terminal host's line in the
    /// owner's log is labeled as the host's, every other line as this source's.
    /// - Parameter lineSource: The line's `source` field, if it has one.
    /// - Returns: ``terminalHost`` for a host line in the owner's log, otherwise this source.
    public func labeling(lineSource: String?) -> RustPanicSource {
        self == .owner && lineSource == Self.terminalHostLineSource ? .terminalHost : self
    }

    /// The PTY holder (`cmux-holder`), which outlives the daemon and the app. Its panics go to
    /// `holder-panics.jsonl` beside its socket, written by cmux-panic-log's std-only writer; its lines carry
    /// `holder_pid`, `holder_socket` and `holder_wire`.
    public static let holder = RustPanicSource(process: "cmux-holder", fingerprintPrefix: "holder-panic",
                                               crashSource: "holder_panic_log", label: "cmux-holder panic")
    /// The acpmux daemon's agent hosts, `acpmux __agent-host` (`$ACPMUX_HOME/agent-host-panics.jsonl`).
    public static let agentHost = RustPanicSource(process: "acpmux-agent-host", fingerprintPrefix: "agent-host-panic",
                                                  crashSource: "agent_host_panic_log", label: "acpmux agent host panic")
    /// The owner's sandboxed first-party app hosts, `cmux-app-host` (`app-host-panics.jsonl` at the owner's state root).
    public static let appHost = RustPanicSource(process: "cmux-app-host", fingerprintPrefix: "app-host-panic",
                                                crashSource: "app_host_panic_log", label: "cmux-app-host panic")
    /// The owner's browser host, `cmux-browser-host serve` (`browser-host-panics.jsonl` at the owner's state root).
    public static let browserHost = RustPanicSource(process: "cmux-browser-host", fingerprintPrefix: "browser-host-panic",
                                                    crashSource: "browser_host_panic_log", label: "cmux-browser-host panic")
    /// `cmux mcp serve` (`mcp-panics.jsonl` at the owner's state root).
    public static let mcp = RustPanicSource(process: "cmux-mcp", fingerprintPrefix: "mcp-panic",
                                            crashSource: "mcp_panic_log", label: "cmux mcp serve panic")
    /// The cmux Cloud server (`cmux-cloud`).
    public static let cloud = RustPanicSource(process: "cmux-cloud", fingerprintPrefix: "cloud-panic",
                                              crashSource: "cloud_panic_log", label: "cmux-cloud panic")
    /// OptChat's chief (`optchat-chief`).
    public static let optchatChief = RustPanicSource(process: "optchat-chief", fingerprintPrefix: "optchat-chief-panic",
                                                     crashSource: "optchat_chief_panic_log", label: "optchat-chief panic")
    /// The diff viewer's sidecar (`cmux-diff-sidecar`).
    public static let diffSidecar = RustPanicSource(process: "cmux-diff-sidecar", fingerprintPrefix: "diff-sidecar-panic",
                                                    crashSource: "diff_sidecar_panic_log", label: "cmux-diff-sidecar panic")
    /// The cmux server's root launchd helper (`cmux-server-helper`).
    public static let serverHelper = RustPanicSource(process: "cmux-server-helper", fingerprintPrefix: "server-helper-panic",
                                                     crashSource: "server_helper_panic_log", label: "cmux-server-helper panic")

    /// The process of a black box of role `ringRole` (`<role>-<pid>.blackbox.cmxtrace`); nil for a role that writes no
    /// Rust diagnostics log (the app, the Chromium host and the CLI).
    public init?(ringRole: TraceRing.Role) {
        switch ringRole {
        case .daemon: self = .owner
        case .holder: self = .holder
        case .terminalHost: self = .terminalHost
        case .acpmux: self = .acpmux
        case .agentHost: self = .agentHost
        case .appHost: self = .appHost
        case .browserHost: self = .browserHost
        case .app, .chromiumHost, .cli: return nil
        }
    }

    /// The first fingerprint element of this process's hang events (cmux-hang-watch lines); the hung
    /// thread's name and its top in-app frames follow it.
    public var hangFingerprintPrefix: String { "\(process)-hang" }

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

    /// The holders' panic log: in the daemon's private holder socket directory
    /// (cmux-tui-core `holder_runtime/service.rs`, `/tmp/cmux-hd-<uid>`), which every holder of the user shares.
    /// - Parameter userID: The user the holders run as (`getuid()`).
    /// - Returns: `/tmp/cmux-hd-<userID>/holder-panics.jsonl`.
    public static func holderLog(userID: UInt32) -> URL {
        URL(filePath: "/tmp/cmux-hd-\(userID)", directoryHint: .isDirectory).appending(path: "holder-panics.jsonl")
    }
}
