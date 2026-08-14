internal import Foundation

/// One process identity alternative whose non-empty criteria are ANDed.
public struct CmuxAgentProcessMatcher: Codable, Equatable, Hashable, Sendable {
    /// Stable identifier shown in diagnostics.
    public var id: String
    /// Executable basenames that may identify the process.
    public var processNames: [String]
    /// Case-insensitive path fragments that must all occur in the executable path.
    public var processPathContains: [String]
    /// Path regex alternatives; one matching pattern is sufficient.
    public var processPathRegex: [CmuxAgentRegexPattern]
    /// Argument fragments that must all occur in the argument vector.
    public var argvContainsAll: [String]
    /// Argument fragments of which at least one must occur.
    public var argvContainsAny: [String]
    /// Script/module basenames used to identify wrapper runtimes such as Python.
    public var argvBasenamesAny: [String]
    /// Environment entries that must equal the captured process environment.
    public var environmentEquals: [String: String]

    /// Creates a process matcher from declarative identity predicates.
    public init(
        id: String = "match",
        processNames: [String] = [],
        processPathContains: [String] = [],
        processPathRegex: [CmuxAgentRegexPattern] = [],
        argvContainsAll: [String] = [],
        argvContainsAny: [String] = [],
        argvBasenamesAny: [String] = [],
        environmentEquals: [String: String] = [:]
    ) {
        self.id = Self.trimmed(id)
        self.processNames = Self.trimmedValues(processNames)
        self.processPathContains = Self.trimmedValues(processPathContains)
        self.processPathRegex = processPathRegex
        self.argvContainsAll = Self.trimmedValues(argvContainsAll)
        self.argvContainsAny = Self.trimmedValues(argvContainsAny)
        self.argvBasenamesAny = Self.trimmedValues(argvBasenamesAny)
        self.environmentEquals = environmentEquals.reduce(into: [:]) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = pair.value
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, processNames, processPathContains, processPathRegex
        case argvContainsAll, argvContainsAny, argvBasenamesAny, environmentEquals
    }

    /// Decodes a matcher while accepting scalar-or-array string shorthands.
    ///
    /// - Parameter decoder: Decoder positioned at one matcher object.
    /// - Throws: ``DecodingError`` when a predicate has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "match",
            processNames: try Self.decodeStrings(container, key: .processNames),
            processPathContains: try Self.decodeStrings(container, key: .processPathContains),
            processPathRegex: try container.decodeIfPresent(
                [CmuxAgentRegexPattern].self,
                forKey: .processPathRegex
            ) ?? [],
            argvContainsAll: try Self.decodeStrings(container, key: .argvContainsAll),
            argvContainsAny: try Self.decodeStrings(container, key: .argvContainsAny),
            argvBasenamesAny: try Self.decodeStrings(container, key: .argvBasenamesAny),
            environmentEquals: try container.decodeIfPresent(
                [String: String].self,
                forKey: .environmentEquals
            ) ?? [:]
        )
    }

    private static func decodeStrings(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values
        }
        if let value = try container.decodeIfPresent(String.self, forKey: key) {
            return [value]
        }
        return []
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedValues(_ values: [String]) -> [String] {
        values.map(trimmed)
    }
}
