/// A sink for the updater's diagnostic log lines.
///
/// The updater records a running, file-backed trace of every Sparkle state transition and
/// decision (`"state -> downloading(42%)"`, `"no update found (reason=onLatestVersion)"`, …).
/// That log is owned by the host application (it predates this package and is also written
/// from app-target call sites), so the package depends only on this seam and the app injects
/// its concrete logger.
///
/// Conformers must be safe to call from any thread and must preserve append order, because
/// entries arrive synchronously from Sparkle's `SPUUserDriver` callbacks.
public protocol UpdateLogging: Sendable {
    /// Appends one line to the update log. Implementations timestamp the line themselves.
    func append(_ message: String)

    /// The current contents of the in-memory log buffer, newest-last, one entry per line.
    /// Surfaced through ``clipboardPayload()`` for the "Copy Update Logs" menu action.
    func snapshot() -> String

    /// The filesystem path of the log file, surfaced to users in error details.
    func logPath() -> String
}

extension UpdateLogging {
    /// The human-readable text the "Copy Update Logs" menu action places on the pasteboard:
    /// the captured log snapshot (or a "no logs" notice) followed by the log file path.
    ///
    /// This is the updater-domain formatting that previously lived inline in `AppDelegate`;
    /// the app target now only writes the returned string to `NSPasteboard`.
    public func clipboardPayload() -> String {
        let logText = snapshot()
        if logText.isEmpty {
            return "No update logs captured.\nLog file: \(logPath())"
        }
        return logText + "\nLog file: \(logPath())"
    }
}
