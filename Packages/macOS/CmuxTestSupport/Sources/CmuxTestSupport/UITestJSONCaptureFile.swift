#if DEBUG
import Foundation

internal import CMUXDebugLog

/// A merge-on-write `[String: Any]` capture file for XCUITest scenarios that
/// persist a **sorted-keys** JSON object to an explicit path.
///
/// The terminal cmd-click recorder accumulates an arbitrary `[String: Any]`
/// payload (ready flags, geometry rects, per-command results) into a single
/// manifest file that an XCUITest run polls. Each write loads the current
/// file, merges the new keys over it, and re-serializes the whole object with
/// `.sortedKeys`, so the fields accumulate across stages with a stable key
/// order.
///
/// This type owns that load / merge / write so the byte format lives in one
/// tested place instead of being inlined at the instrumentation point. It is
/// deliberately distinct from its two siblings:
/// - ``UITestKeyValueCaptureFile`` stores flat `[String: String]` fields and
///   writes **unsorted** keys, so it cannot represent the nested geometry
///   payloads this recorder emits.
/// - ``UITestCaptureSink/mutateJSONObjectIfConfigured(envKey:_:)`` also
///   serializes `[String: Any]` with `.sortedKeys`, but keys on an environment
///   variable, creates the parent directory **before** serializing (so the
///   directory appears even when serialization fails), and never logs. This
///   type resolves an explicit path, creates the parent directory only on the
///   successful-serialize write path, and logs a debug line on a serialization
///   or write failure, reproducing the legacy inline writer byte-for-byte.
///
/// Isolation: a stateless `Sendable` struct. The only stored values are the
/// capture-file path and the debug-log label; all I/O happens synchronously
/// inside method scope on the calling thread (matching the legacy inline
/// writer's timing so captures stay ordered with the interactions they
/// record).
public struct UITestJSONCaptureFile: Sendable {
    private let path: String
    private let logLabel: String

    /// Creates a capture file bound to `path`.
    ///
    /// - Parameters:
    ///   - path: The absolute capture-file path the recorder resolved from its
    ///     scenario environment variable.
    ///   - logLabel: The prefix used for the debug-log lines emitted on a
    ///     serialization or write failure (the legacy writer used
    ///     `"cmdclick.ui.write"`).
    public init(path: String, logLabel: String) {
        self.path = path
        self.logLabel = logLabel
    }

    /// Merges `updates` over the current capture object and writes the result
    /// back atomically with **sorted** keys.
    ///
    /// An absent or unparsable file is treated as empty before merging. A
    /// serialization failure logs `"<logLabel> skip reason=json path=<path>"`
    /// and leaves the file untouched (without creating the parent directory).
    /// On a successful serialize the parent directory is created with
    /// intermediate directories before the atomic write; a write failure logs
    /// `"<logLabel> error path=<path> error=<description>"`. This matches the
    /// legacy inline writer exactly.
    ///
    /// - Parameter updates: The keys to overwrite or insert.
    public func merge(_ updates: [String: Any]) {
        let url = URL(fileURLWithPath: path)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            logDebugEvent("\(logLabel) skip reason=json path=\(path)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            logDebugEvent("\(logLabel) error path=\(path) error=\(error.localizedDescription)")
        }
    }
}
#endif
