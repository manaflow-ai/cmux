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
    /// A cmux-tui terminal host. Its owner appends the host's `.crash` sidecar to the owner's log as one
    /// line with `"source": "cmux-tui-host"` before it deletes the sidecar (cmux-tui-core `host_crash.rs`).
    public static let terminalHost = RustPanicSource(process: "cmux-tui-host", fingerprintPrefix: "host-panic",
                                                     crashSource: "terminal_host_crash",
                                                     label: "cmux-tui terminal host panic")
    /// The `source` field of a terminal host's line in the owner's log.
    public static let terminalHostLineSource = "cmux-tui-host"

    /// The source that labels one line of the log this source reads: a terminal host's line in the
    /// owner's log is labeled as the host's, every other line as this source's.
    /// - Parameter lineSource: The line's `source` field, if it has one.
    /// - Returns: ``terminalHost`` for a host line in the owner's log, otherwise this source.
    public func labeling(lineSource: String?) -> RustPanicSource {
        self == .owner && lineSource == Self.terminalHostLineSource ? .terminalHost : self
    }

    /// The acpmux daemon's panic log under its home (`ACPMUX_HOME`).
    /// - Parameter acpmuxHome: The daemon's `ACPMUX_HOME`.
    /// - Returns: `<acpmuxHome>/panics.jsonl`.
    public static func acpmuxLog(acpmuxHome: URL) -> URL {
        acpmuxHome.appending(path: "panics.jsonl")
    }
}
