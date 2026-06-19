public import Foundation
internal import QuartzCore

/// Append-only debug log for terminal background/theme/OSC color events.
///
/// Replaces the `backgroundLogEnabled` / `backgroundLogURL` / `backgroundLogLock`
/// / `backgroundLogSequence` state and the `logBackground(_:)` /
/// `resolveBackgroundLogURL(_:)` helpers that lived on the `GhosttyApp` god
/// type. It is a self-contained side-effecting capability (disk I/O) with no
/// view coupling, so it folds into the engine as its own service.
///
/// Isolation design: `log(_:)` is invoked from both the main actor (theme/reload
/// paths) and Ghostty I/O / OSC callbacks that run off-main (the line records
/// `thread=main`/`thread=background` precisely because callers are mixed), so
/// this type cannot be `@MainActor`. The legacy implementation serialized the
/// sequence counter and file append behind an `NSLock`; that exact shape is the
/// sanctioned primitive for a tiny value mutated by synchronous off-isolation
/// callers, so the type stays nonisolated and `Sendable` with byte-identical
/// observable behavior.
public final class BackgroundDebugLog: Sendable {
    private let enabled: Bool
    private let url: URL
    private let startUptime: TimeInterval
    private let lock = NSLock()
    // SAFETY: guarded by `lock`; the monotonically increasing sequence stamped
    // on each appended line, mutated only inside `log(_:)` under the lock.
    nonisolated(unsafe) private var sequence: UInt64 = 0

    /// Creates the log, resolving its enabled flag and destination from the
    /// given process environment and defaults exactly as the legacy `GhosttyApp`
    /// initializers did. The composition root passes
    /// `ProcessInfo.processInfo.environment`, `.standard`, and
    /// `ProcessInfo.processInfo.systemUptime`.
    public init(
        environment: [String: String],
        defaults: UserDefaults,
        startUptime: TimeInterval
    ) {
        self.enabled = Self.resolveEnabled(environment: environment, defaults: defaults)
        self.url = Self.resolveURL(environment: environment)
        self.startUptime = startUptime
    }

    /// Whether background logging is active. Callers gate string-building work on
    /// this so normal runs perform no formatting or I/O.
    public var isEnabled: Bool { enabled }

    /// Appends one timestamped, sequence-stamped line to the log file. A no-op
    /// when logging is disabled.
    public func log(_ message: String) {
        // Skip all work (string formatting and disk I/O) unless background logging is
        // explicitly enabled via env/defaults. Without this guard, direct callers wrote
        // to /tmp/cmux-bg.log on every theme/OSC color event even in normal runs.
        guard enabled else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let uptimeMs = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        let frame60 = Int((CACurrentMediaTime() * 60.0).rounded(.down))
        let frame120 = Int((CACurrentMediaTime() * 120.0).rounded(.down))
        let threadLabel = Thread.isMainThread ? "main" : "background"
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        let sequence = sequence
        let line =
            "\(timestamp) seq=\(sequence) t+\(String(format: "%.3f", uptimeMs))ms thread=\(threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) == false {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: data)
            }
        }
    }

    private static func resolveEnabled(
        environment: [String: String],
        defaults: UserDefaults
    ) -> Bool {
        if environment["CMUX_DEBUG_BG"] == "1" {
            return true
        }
        if environment["CMUX_DEBUG_LOG"] != nil {
            return true
        }
        return defaults.bool(forKey: "cmuxDebugBG")
    }

    private static func resolveURL(environment: [String: String]) -> URL {
        if let explicitPath = environment["CMUX_DEBUG_BG_LOG"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        if let debugLogPath = environment["CMUX_DEBUG_LOG"],
           !debugLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let baseURL = URL(fileURLWithPath: debugLogPath)
            let extensionSeparatorIndex = baseURL.lastPathComponent.lastIndex(of: ".")
            let stem = extensionSeparatorIndex.map { String(baseURL.lastPathComponent[..<$0]) } ?? baseURL.lastPathComponent
            let bgName = "\(stem)-bg.log"
            return baseURL.deletingLastPathComponent().appendingPathComponent(bgName)
        }

        return URL(fileURLWithPath: "/tmp/cmux-bg.log")
    }
}
