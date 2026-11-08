import Foundation

/// One revertible mutation in the accumulated design-mode edit set.
public struct BrowserDesignModeEdit: Codable, Equatable, Identifiable, Sendable {
    /// The stable edit identifier used for per-edit reverts.
    public let id: String
    /// Whether the edit changes CSS or text.
    public let kind: BrowserDesignModeEditKind
    /// The CSS property name, or `text-content` for a text edit.
    public let property: String
    /// The value observed before design mode changed the element.
    public let originalValue: String
    /// The currently requested value.
    public let value: String

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case property
        case originalValue = "original_value"
        case value
    }

    /// Creates a design-mode edit.
    /// - Parameters:
    ///   - id: The stable edit identifier.
    ///   - kind: The edit kind.
    ///   - property: The CSS property or text sentinel.
    ///   - originalValue: The value before editing.
    ///   - value: The requested replacement value.
    public init(
        id: String,
        kind: BrowserDesignModeEditKind,
        property: String,
        originalValue: String,
        value: String
    ) {
        self.id = id
        self.kind = kind
        self.property = property
        self.originalValue = originalValue
        self.value = value
    }
}
