#if canImport(UIKit)
import Foundation
import OSLog

// lint:allow namespace-enum — DEBUG input-trace logger on the off-limits typing-latency render path; type reshape deferred to the GhosttySurfaceView UI-god-object split wave.
enum TerminalInputDebugLog {
    #if DEBUG
    private static let isEnabled = ProcessInfo.processInfo.environment["CMUX_INPUT_DEBUG"] == "1"
    private static let logger = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.input")
    #endif

    /// Logs an input-trace line in DEBUG builds when `CMUX_INPUT_DEBUG=1`.
    /// The message is an autoclosure so the interpolation (including
    /// `dataSummary`'s per-byte hex formatting) never runs on the typing hot
    /// path unless the trace is actually enabled. Release builds compile to a
    /// no-op, so typed user content can never reach the unified log there.
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        guard isEnabled else { return }
        let text = message()
        logger.debug("input: \(text, privacy: .public)")
        #endif
    }

    static func textSummary(_ text: String) -> String {
        let summary = String(reflecting: text)
        guard summary.count > 96 else { return summary }
        return "\(summary.prefix(96))..."
    }

    static func dataSummary(_ data: Data) -> String {
        let prefix = data.prefix(32)
        let prefixData = Data(prefix)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        let utf8 = String(data: prefixData, encoding: .utf8) ?? "<non-utf8>"
        let suffix = data.count > prefix.count ? " ..." : ""
        return "len=\(data.count) hex=\(hex)\(suffix) utf8=\(textSummary(utf8))"
    }
}
#endif
