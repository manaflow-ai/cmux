public import Foundation

/// Which cmux Rust process wrote a panic or hang log, and how its records are labeled in Sentry.
///
/// Every panic log has the `cmux-panic-log` line format (one JSON object per
/// panic: `message`, `location`, `thread`, `backtrace`, `test`, plus the
/// process's own fields); a hang log has one `"event": "hang"` object per hung
/// scope (`scope`, `method`, `busy_ms`, `stack`). The source sets the `process`
/// and `crash_source` tags and the fingerprint prefix, so each process's
/// records group apart.
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

    /// The owner's hang log (`owner-hangs-<session>.jsonl`): its request watchdog's mux-conn,
    /// journal-writer and holder-link scopes, and each holder's report of its own loop.
    public static let ownerHangs = RustPanicSource(process: "cmux-tui", fingerprintPrefix: "owner-hang",
                                                   crashSource: "owner_hang_log", label: "cmux-tui owner hang")
    /// The acpmux daemon's hang log (`$ACPMUX_HOME/hangs.jsonl`).
    public static let acpmuxHangs = RustPanicSource(process: "acpmux", fingerprintPrefix: "acpmux-hang",
                                                    crashSource: "acpmux_hang_log", label: "acpmux daemon hang")
    /// The session's terminal holder (`holder-panics.jsonl` in its terminal host root), the one
    /// process that keeps every terminal's PTY.
    public static let holder = RustPanicSource(process: "cmux-holder", fingerprintPrefix: "holder-panic",
                                               crashSource: "holder_panic_log", label: "cmux-holder panic")
    /// A panic an in-app Rust export caught in its FFI boundary (cmux-ffi-guard's panic ring).
    public static let ffiBoundary = RustPanicSource(process: "cmux", fingerprintPrefix: "ffi-panic",
                                                    crashSource: "ffi_panic_ring", label: "in-app Rust FFI panic")

    /// The acpmux daemon's panic log under its home (`ACPMUX_HOME`).
    /// - Parameter acpmuxHome: The daemon's `ACPMUX_HOME`.
    /// - Returns: `<acpmuxHome>/panics.jsonl`.
    public static func acpmuxLog(acpmuxHome: URL) -> URL {
        acpmuxHome.appending(path: "panics.jsonl")
    }

    /// The panic log of the terminal holder of `session`: `holder-panics.jsonl` in the session's
    /// terminal host root, `<sessions>/terminal-hosts-<FNV-1a 64 of the session, 16 hex digits>`
    /// (cmux-tui-core `terminal_host_root` and `diagnostics::holder_panic_log_path`).
    /// - Parameters:
    ///   - sessionsDirectory: The owner's sessions directory (`CMUX_TUI_STATE_DIR` or its default).
    ///   - session: The daemon session.
    /// - Returns: The holder's panic log.
    public static func holderLog(sessionsDirectory: URL, session: String) -> URL {
        let hash = session.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        let token = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        return sessionsDirectory.appending(path: "terminal-hosts-\(token)", directoryHint: .isDirectory)
            .appending(path: "holder-panics.jsonl")
    }

    /// The acpmux daemon's hang log, beside its panic log.
    /// - Parameter acpmuxHome: The daemon's `ACPMUX_HOME`.
    /// - Returns: `<acpmuxHome>/hangs.jsonl`.
    public static func acpmuxHangLog(acpmuxHome: URL) -> URL {
        acpmuxHome.appending(path: "hangs.jsonl")
    }
}
