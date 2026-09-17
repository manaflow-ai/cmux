import Foundation

/// The complete context copied for a coding agent from selected page elements.
public struct BrowserDesignModePromptContext: Equatable, Sendable {
    /// The page URL containing the edited element, reduced to safe structure and field names.
    public let pageURL: String
    /// The authoritative design-mode snapshot.
    public let snapshot: BrowserDesignModeSnapshot
    /// Local PNG crop paths aligned with ``BrowserDesignModeSnapshot/selections``.
    public let screenshotPaths: [String?]
    /// The local PNG crop path for the most recently selected element.
    public var screenshotPath: String? { screenshotPaths.last ?? nil }
    /// A full-viewport PNG path for spatial context around the selections.
    public let pageScreenshotPath: String?
    /// The optional source-level change requested by the user.
    public let requestedChange: String
    /// The instruction in composed order: text runs interleaved with pill
    /// references (by primary selector). Empty when order is unknown.
    public let prompt: [BrowserDesignModePromptRun]

    /// Creates the context for one clipboard handoff.
    /// - Parameters:
    ///   - pageURL: The page URL. User information, route segments, and values are redacted.
    ///   - snapshot: The current design-mode snapshot.
    ///   - screenshotPath: The local screenshot crop path for a single reference.
    ///   - requestedChange: The source-level change the user described, or an empty string for reference-only context.
    public init(
        pageURL: String,
        snapshot: BrowserDesignModeSnapshot,
        screenshotPath: String?,
        requestedChange: String,
        pageScreenshotPath: String? = nil,
        prompt: [BrowserDesignModePromptRun] = []
    ) {
        self.pageURL = BrowserDesignModePageURL(rawValue: pageURL).sanitizedValue
        self.snapshot = snapshot
        self.screenshotPaths = snapshot.selections.isEmpty
            ? []
            : Array(repeating: nil, count: snapshot.selections.count - 1) + [screenshotPath]
        self.pageScreenshotPath = pageScreenshotPath
        self.requestedChange = requestedChange
        self.prompt = prompt
    }

    /// Creates context for an ordered stack of element references.
    /// - Parameters:
    ///   - pageURL: The page URL. User information, route segments, and values are redacted.
    ///   - snapshot: The current design-mode snapshot.
    ///   - screenshotPaths: Local screenshot crop paths aligned with the snapshot's ordered selections.
    ///   - requestedChange: The source-level change the user described, or an empty string for reference-only context.
    public init(
        pageURL: String,
        snapshot: BrowserDesignModeSnapshot,
        screenshotPaths: [String?],
        requestedChange: String,
        pageScreenshotPath: String? = nil,
        prompt: [BrowserDesignModePromptRun] = []
    ) {
        self.pageURL = BrowserDesignModePageURL(rawValue: pageURL).sanitizedValue
        self.snapshot = snapshot
        self.screenshotPaths = screenshotPaths
        self.pageScreenshotPath = pageScreenshotPath
        self.requestedChange = requestedChange
        self.prompt = prompt
    }
}
