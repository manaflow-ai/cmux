import Foundation

/// An authoritative, revisioned snapshot returned by the page runtime.
public struct BrowserDesignModeSnapshot: Codable, Equatable, Sendable {
    /// The monotonic runtime revision.
    public let revision: Int
    /// Whether element picking is active in the current document.
    public let enabled: Bool
    /// The most recently selected element, when one is still resolvable.
    public let selection: BrowserDesignModeSelection?
    /// The ordered element references accumulated in the composer.
    public let selections: [BrowserDesignModeSelection]
    /// The accumulated, individually revertible edits.
    public let edits: [BrowserDesignModeEdit]
    /// A diff-formatted CSS representation of every accumulated style edit.
    public let cssDiff: String

    private enum CodingKeys: String, CodingKey {
        case revision
        case enabled
        case selection
        case selections
        case edits
        case cssDiff = "css_diff"
    }

    /// Creates an authoritative runtime snapshot.
    /// - Parameters:
    ///   - revision: The monotonic runtime revision.
    ///   - enabled: Whether design mode is active.
    ///   - selection: The most recently selected element context.
    ///   - selections: The ordered composer references. When omitted, `selection` becomes the only reference.
    ///   - edits: The accumulated edits.
    ///   - cssDiff: The generated CSS diff.
    public init(
        revision: Int,
        enabled: Bool,
        selection: BrowserDesignModeSelection?,
        selections: [BrowserDesignModeSelection]? = nil,
        edits: [BrowserDesignModeEdit],
        cssDiff: String
    ) {
        self.revision = revision
        self.enabled = enabled
        let resolvedSelections = selections ?? selection.map { [$0] } ?? []
        self.selection = resolvedSelections.last
        self.selections = resolvedSelections
        self.edits = edits
        self.cssDiff = cssDiff
    }

    /// Decodes a snapshot while accepting the earlier single-selection wire format.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        let decodedSelection = try container.decodeIfPresent(BrowserDesignModeSelection.self, forKey: .selection)
        selections = try container.decodeIfPresent([BrowserDesignModeSelection].self, forKey: .selections)
            ?? decodedSelection.map { [$0] }
            ?? []
        selection = selections.last
        edits = try container.decode([BrowserDesignModeEdit].self, forKey: .edits)
        cssDiff = try container.decode(String.self, forKey: .cssDiff)
    }

    /// Encodes both the ordered references and the active selection compatibility field.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(selection, forKey: .selection)
        try container.encode(selections, forKey: .selections)
        try container.encode(edits, forKey: .edits)
        try container.encode(cssDiff, forKey: .cssDiff)
    }
}
