public import Foundation

/// The outcome of capturing a browser surface screenshot for
/// `browser.screenshot`, preserving the legacy timeout vs capture-failure
/// error distinction.
public enum ControlBrowserScreenshotResult: Sendable, Equatable {
    /// The PNG-encoded viewport snapshot.
    case png(Data)
    /// The snapshot callback never completed within the legacy 15s budget
    /// (`timeout` / "Timed out waiting for snapshot").
    case timedOut
    /// The capture or PNG encode failed (`internal_error` / "Failed to
    /// capture snapshot").
    case captureFailed
}
