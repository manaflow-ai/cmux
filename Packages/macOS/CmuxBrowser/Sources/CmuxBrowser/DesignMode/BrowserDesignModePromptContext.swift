import Foundation

/// The complete context packaged for a coding agent after visual editing.
public nonisolated struct BrowserDesignModePromptContext: Equatable, Sendable {
    /// The page URL containing the edited element, with query-like values redacted.
    public let pageURL: String
    /// The authoritative design-mode snapshot.
    public let snapshot: BrowserDesignModeSnapshot
    /// The local PNG crop path, when capture succeeded.
    public let screenshotPath: String?

    /// Creates the context for one agent handoff.
    /// - Parameters:
    ///   - pageURL: The page URL. User information and query-like values are redacted.
    ///   - snapshot: The current design-mode snapshot.
    ///   - screenshotPath: The local screenshot crop path.
    public init(pageURL: String, snapshot: BrowserDesignModeSnapshot, screenshotPath: String?) {
        self.pageURL = BrowserDesignModePageURL(rawValue: pageURL).sanitizedValue
        self.snapshot = snapshot
        self.screenshotPath = screenshotPath
    }
}
