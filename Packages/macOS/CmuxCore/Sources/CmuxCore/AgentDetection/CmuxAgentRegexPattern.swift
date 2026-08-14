internal import Foundation

/// A regular expression compiled and validated before catalog admission.
public struct CmuxAgentRegexPattern: Codable, Equatable, Hashable, Sendable {
    /// ICU regular-expression source.
    public var pattern: String
    /// Whether matching ignores letter case.
    public var caseInsensitive: Bool
    /// Whether `.` also matches line separators.
    public var dotMatchesNewlines: Bool

    /// Creates a regex condition.
    public init(
        pattern: String,
        caseInsensitive: Bool = true,
        dotMatchesNewlines: Bool = true
    ) {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
        self.dotMatchesNewlines = dotMatchesNewlines
    }

    /// Decodes either a shorthand string or an options object.
    ///
    /// - Parameter decoder: Decoder positioned at a regex string or object.
    /// - Throws: ``DecodingError`` when the value has an unsupported shape.
    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self.init(pattern: value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pattern: try container.decode(String.self, forKey: .pattern),
            caseInsensitive: try container.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? true,
            dotMatchesNewlines: try container.decodeIfPresent(Bool.self, forKey: .dotMatchesNewlines) ?? true
        )
    }

    private enum CodingKeys: String, CodingKey {
        case pattern, caseInsensitive, dotMatchesNewlines
    }
}
