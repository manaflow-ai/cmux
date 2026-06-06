public import Foundation
internal import OSLog

/// Best-effort reader of the current process's unified-log entries, used as a
/// *supplement* to the in-process ``MobileDebugLogSink`` (the primary log
/// source) in a diagnostics report.
///
/// Reading the app's own process log (`OSLogStore(scope: .currentProcessIdentifier)`)
/// needs no special entitlement. It is best-effort only: any failure is caught
/// and surfaced as a one-line note rather than failing the whole report. Note
/// that interpolations logged without `privacy: .public` are redacted to
/// `<private>` by the OS when an app reads its own store, which is exactly why
/// the sink (real strings) is primary and this is a supplement.
///
/// ```swift
/// let reader = MobileDiagnosticsOSLogReader()
/// let section = await reader.recentEntriesText()
/// ```
public actor MobileDiagnosticsOSLogReader {
    private let subsystems: Set<String>
    private let lookback: TimeInterval
    private let maxEntries: Int
    private let maxBytes: Int

    /// Creates an OS-log reader.
    ///
    /// - Parameters:
    ///   - subsystems: The OSLog subsystems to include. Defaults to the cmux iOS
    ///     subsystem set plus the running bundle identifier (which
    ///     ``MobileShellComposite`` logs under at runtime).
    ///   - lookback: How far back to read, in seconds. Defaults to `300` (5 min).
    ///   - maxEntries: Maximum matching entries to include. Defaults to `200`.
    ///   - maxBytes: Approximate UTF-8 byte budget for the formatted text.
    ///     Defaults to `128 KiB`.
    public init(
        subsystems: Set<String> = MobileDiagnosticsOSLogReader.defaultSubsystems,
        lookback: TimeInterval = 300,
        maxEntries: Int = 200,
        maxBytes: Int = 128 * 1024
    ) {
        self.subsystems = subsystems
        self.lookback = lookback
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    /// The cmux iOS OSLog subsystems, plus the running bundle identifier.
    ///
    /// The three literals are the declared `Logger(subsystem:)` values across the
    /// iOS packages; the bundle identifier covers ``MobileShellComposite``, which
    /// logs under `Bundle.main.bundleIdentifier` rather than a hardcoded string.
    public static var defaultSubsystems: Set<String> {
        var set: Set<String> = [
            "ai.manaflow.cmux",
            "ai.manaflow.cmux.ios",
            "com.cmuxterm.app",
        ]
        if let bundleID = Bundle.main.bundleIdentifier {
            set.insert(bundleID)
        }
        return set
    }

    /// Returns a formatted section of recent process log entries, or a one-line
    /// unavailability note on any failure.
    ///
    /// Each entry is rendered as `time category [level] subsystem: message`.
    /// Entries are filtered to ``subsystems`` and the ``lookback`` window. This
    /// never throws: failures (no store access, no entries API on the platform)
    /// produce a stable sanitized unavailability note.
    ///
    /// - Returns: The formatted entries text, or an unavailability note.
    public func recentEntriesText() -> String {
        #if canImport(OSLog)
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-lookback))
            let entries = try store.getEntries(at: since)

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"

            var lines: [String] = []
            var renderedBytes = 0
            var truncated = false
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                guard subsystems.contains(logEntry.subsystem) else { continue }
                let time = formatter.string(from: logEntry.date)
                let level = Self.levelLabel(logEntry.level)
                let category = logEntry.category.isEmpty ? "-" : logEntry.category
                let line = "\(time) \(category) [\(level)] \(logEntry.subsystem): \(logEntry.composedMessage)"
                guard Self.appendCappedLine(
                    line,
                    to: &lines,
                    renderedBytes: &renderedBytes,
                    maxEntries: maxEntries,
                    maxBytes: maxBytes
                ) else {
                    truncated = true
                    break
                }
            }

            if lines.isEmpty {
                return truncated
                    ? "(os log truncated before first matching entry)"
                    : "(no matching os log entries in the last \(Int(lookback))s)"
            }
            if truncated {
                _ = Self.appendCappedLine(
                    "(os log truncated)",
                    to: &lines,
                    renderedBytes: &renderedBytes,
                    maxEntries: maxEntries,
                    maxBytes: maxBytes
                )
            }
            return lines.joined(separator: "\n")
        } catch {
            return "(os log unavailable: read failed)"
        }
        #else
        return "(os log unavailable: OSLog not importable on this platform)"
        #endif
    }

    #if canImport(OSLog)
    /// Short human label for an OSLog entry level.
    private static func levelLabel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "undefined"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "unknown"
        }
    }
    #endif

    @discardableResult
    static func appendCappedLine(
        _ line: String,
        to lines: inout [String],
        renderedBytes: inout Int,
        maxEntries: Int,
        maxBytes: Int
    ) -> Bool {
        guard maxEntries > 0, maxBytes > 0 else { return false }
        guard lines.count < maxEntries else { return false }
        let separatorBytes = lines.isEmpty ? 0 : 1
        let candidateBytes = line.utf8.count
        guard renderedBytes + separatorBytes + candidateBytes <= maxBytes else {
            return false
        }
        lines.append(line)
        renderedBytes += separatorBytes + candidateBytes
        return true
    }
}
