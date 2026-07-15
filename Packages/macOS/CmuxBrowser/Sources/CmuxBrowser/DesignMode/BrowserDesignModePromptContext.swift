import Foundation

/// The complete context copied for a coding agent from a selected page element.
public nonisolated struct BrowserDesignModePromptContext: Equatable, Sendable {
    /// The page URL containing the edited element, reduced to safe structure and field names.
    public let pageURL: String
    /// The authoritative design-mode snapshot.
    public let snapshot: BrowserDesignModeSnapshot
    /// The local PNG crop path, when capture succeeded.
    public let screenshotPath: String?
    /// The optional source-level change requested by the user.
    public let requestedChange: String

    /// Creates the context for one clipboard handoff.
    /// - Parameters:
    ///   - pageURL: The page URL. User information, route segments, and values are redacted.
    ///   - snapshot: The current design-mode snapshot.
    ///   - screenshotPath: The local screenshot crop path.
    ///   - requestedChange: The source-level change the user described, or an empty string for reference-only context.
    public init(
        pageURL: String,
        snapshot: BrowserDesignModeSnapshot,
        screenshotPath: String?,
        requestedChange: String
    ) {
        self.pageURL = BrowserDesignModePageURL(rawValue: pageURL).sanitizedValue
        self.snapshot = snapshot
        self.screenshotPath = screenshotPath
        self.requestedChange = requestedChange
    }
}
