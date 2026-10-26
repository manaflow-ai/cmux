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

    /// The `cmux/cloud` app server (`<CMUX_APP_DATA_DIR>/panics.jsonl`).
    public static let cloud = RustPanicSource(process: "cmux-cloud", fingerprintPrefix: "cmux-cloud-panic",
                                              crashSource: "cmux_cloud_panic_log", label: "cmux-cloud server panic")
    /// The OptChat Chief (`$MUX_HOME/optchat/panics.jsonl`).
    public static let optchatChief = RustPanicSource(process: "optchat-chief", fingerprintPrefix: "optchat-chief-panic",
                                                     crashSource: "optchat_chief_panic_log", label: "optchat-chief panic")
    /// The diff viewer's sidecar (`<diff root>/.sidecar-panics.jsonl`).
    public static let diffSidecar = RustPanicSource(process: "cmux-diff-sidecar", fingerprintPrefix: "diff-sidecar-panic",
                                                    crashSource: "diff_sidecar_panic_log", label: "cmux-diff-sidecar panic")

    /// The acpmux daemon's panic log under its home (`ACPMUX_HOME`).
    /// - Parameter acpmuxHome: The daemon's `ACPMUX_HOME`.
    /// - Returns: `<acpmuxHome>/panics.jsonl`.
    public static func acpmuxLog(acpmuxHome: URL) -> URL {
        acpmuxHome.appending(path: "panics.jsonl")
    }

    /// The `cmux/cloud` server's panic log (cmux-cloud `panic_log.rs`).
    /// - Parameter appDataDirectory: The server's `CMUX_APP_DATA_DIR`
    ///   (`<session state>/apps-data/cmux.cloud`).
    /// - Returns: `<appDataDirectory>/panics.jsonl`.
    public static func cloudLog(appDataDirectory: URL) -> URL {
        appDataDirectory.appending(path: "panics.jsonl")
    }

    /// The OptChat Chief's panic log (optchat-chief `panic_log.rs`).
    /// - Parameter muxHome: The Chief's `MUX_HOME`.
    /// - Returns: `<muxHome>/optchat/panics.jsonl`.
    public static func optchatChiefLog(muxHome: URL) -> URL {
        muxHome.appending(path: "optchat", directoryHint: .isDirectory).appending(path: "panics.jsonl")
    }

    /// The diff sidecar's panic log (cmux-diff-sidecar `panic_log.rs`).
    /// - Parameter diffRoot: The sidecar's `--root`.
    /// - Returns: `<diffRoot>/.sidecar-panics.jsonl`.
    public static func diffSidecarLog(diffRoot: URL) -> URL {
        diffRoot.appending(path: ".sidecar-panics.jsonl")
    }
}
