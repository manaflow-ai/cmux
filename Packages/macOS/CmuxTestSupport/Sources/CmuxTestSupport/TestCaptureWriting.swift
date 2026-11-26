public import Foundation

/// Capture seam for UI-test instrumentation.
///
/// Production code calls these at interaction points (file opens, drag
/// geometry, settings-window state) so XCUITest runs can observe internal
/// state through capture files. Each call names the environment variable
/// that carries the capture file path for that instrumentation point; when
/// the variable is unset the call is a no-op and reports `false`, which is
/// how production stays side-effect free without build-time branching.
public protocol TestCaptureWriting: Sendable {
    /// Appends `line` (plus a trailing newline) to the capture file named by
    /// `envKey`, creating the file and its parent directory if needed.
    ///
    /// - Returns: `true` when a capture file was configured (the caller
    ///   should treat the interaction as intercepted), `false` when capture
    ///   is not configured and the caller should proceed normally.
    @discardableResult
    func appendLineIfConfigured(envKey: String, line: String) -> Bool

    /// Reads the JSON object in the capture file named by `envKey` (an
    /// absent or unparsable file reads as `[:]`), applies `update`, and
    /// writes the result back atomically with sorted keys.
    ///
    /// - Returns: `true` when a capture file was configured, `false`
    ///   otherwise (no I/O performed).
    @discardableResult
    func mutateJSONObjectIfConfigured(
        envKey: String,
        _ update: (inout [String: Any]) -> Void
    ) -> Bool
}
