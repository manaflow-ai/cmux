import Foundation

/// An authoritative, revisioned snapshot returned by the page runtime.
public nonisolated struct BrowserDesignModeSnapshot: Codable, Equatable, Sendable {
    /// The monotonic runtime revision.
    public let revision: Int
    /// Whether element picking is active in the current document.
    public let enabled: Bool
    /// The selected element, when one is still resolvable.
    public let selection: BrowserDesignModeSelection?
    /// The accumulated, individually revertible edits.
    public let edits: [BrowserDesignModeEdit]
    /// A diff-formatted CSS representation of every accumulated style edit.
    public let cssDiff: String

    private enum CodingKeys: String, CodingKey {
        case revision
        case enabled
        case selection
        case edits
        case cssDiff = "css_diff"
    }

    /// Creates an authoritative runtime snapshot.
    /// - Parameters:
    ///   - revision: The monotonic runtime revision.
    ///   - enabled: Whether design mode is active.
    ///   - selection: The selected element context.
    ///   - edits: The accumulated edits.
    ///   - cssDiff: The generated CSS diff.
    public init(
        revision: Int,
        enabled: Bool,
        selection: BrowserDesignModeSelection?,
        edits: [BrowserDesignModeEdit],
        cssDiff: String
    ) {
        self.revision = revision
        self.enabled = enabled
        self.selection = selection
        self.edits = edits
        self.cssDiff = cssDiff
    }
}
