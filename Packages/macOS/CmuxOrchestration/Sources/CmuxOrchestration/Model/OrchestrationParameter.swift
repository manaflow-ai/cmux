import Foundation

/// A scalar value carried by a parameter default or a resolved parameter.
///
/// JSON has no integer/bool/string union type, so this enum preserves the
/// author's JSON type through encode/decode round trips instead of
/// stringifying everything at the edges.
public enum OrchestrationParameterValue: Sendable, Hashable, Codable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case bool(Bool)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Parameter values must be a string, integer, or boolean"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    /// The value rendered into prompt/command placeholders.
    public var description: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
}

/// The declared type of an install-time parameter.
public enum OrchestrationParameterType: String, Sendable, Codable, CaseIterable {
    /// Free-form text.
    case string
    /// Integer, e.g. a concurrency cap.
    case int
    /// Boolean toggle.
    case bool
    /// Filesystem path; `~` is expanded at resolution time.
    case path
    /// One of the values listed in `choices`.
    case choice
    /// The id of an agent declared in the manifest's `agents` array.
    case agent
}

/// One install-time interview question.
///
/// Parameters describe machine-specific inputs (target repo, workspace root,
/// agent choice, concurrency). Resolved values are stored per-install on the
/// user's machine — never inside the template — so a shared template stays
/// portable.
public struct OrchestrationParameter: Sendable, Hashable, Codable {
    public var key: String
    public var prompt: String
    public var type: OrchestrationParameterType
    public var defaultValue: OrchestrationParameterValue?
    /// Allowed values when `type == .choice`.
    public var choices: [String]?

    enum CodingKeys: String, CodingKey {
        case key
        case prompt
        case type
        case defaultValue = "default"
        case choices
    }

    public init(
        key: String,
        prompt: String,
        type: OrchestrationParameterType = .string,
        defaultValue: OrchestrationParameterValue? = nil,
        choices: [String]? = nil
    ) {
        self.key = key
        self.prompt = prompt
        self.type = type
        self.defaultValue = defaultValue
        self.choices = choices
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(String.self, forKey: .key)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        // `type` is optional in the JSON; free-form text is the common case.
        self.type = try container.decodeIfPresent(OrchestrationParameterType.self, forKey: .type) ?? .string
        self.defaultValue = try container.decodeIfPresent(OrchestrationParameterValue.self, forKey: .defaultValue)
        self.choices = try container.decodeIfPresent([String].self, forKey: .choices)
    }

    /// A parameter with no default must be answered before a run can start.
    public var isRequired: Bool {
        defaultValue == nil
    }

    /// Parameter keys are placeholder identifiers: lowercase ASCII letters,
    /// digits, and underscores, starting with a letter.
    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLowercase, first.isLetter else {
            return false
        }
        return key.allSatisfy { character in
            character.isASCII && (character.isLowercase && character.isLetter || character.isNumber || character == "_")
        }
    }

    /// Validates that `value` matches the declared type, returning a
    /// normalized value or a human-readable problem description.
    public func coerce(_ raw: String) -> Result<OrchestrationParameterValue, OrchestrationParameterProblem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .string, .path, .agent:
            guard !trimmed.isEmpty else {
                return .failure(.init(key: key, reason: "value must not be empty"))
            }
            return .success(.string(trimmed))
        case .int:
            guard let number = Int(trimmed) else {
                return .failure(.init(key: key, reason: "expected an integer, got '\(raw)'"))
            }
            return .success(.int(number))
        case .bool:
            switch trimmed.lowercased() {
            case "true", "yes", "y", "1": return .success(.bool(true))
            case "false", "no", "n", "0": return .success(.bool(false))
            default:
                return .failure(.init(key: key, reason: "expected true/false, got '\(raw)'"))
            }
        case .choice:
            let allowed = choices ?? []
            guard allowed.contains(trimmed) else {
                let list = allowed.joined(separator: ", ")
                return .failure(.init(key: key, reason: "expected one of [\(list)], got '\(raw)'"))
            }
            return .success(.string(trimmed))
        }
    }
}

/// A parameter value that failed type validation.
public struct OrchestrationParameterProblem: Error, Sendable, Hashable {
    public var key: String
    public var reason: String

    public init(key: String, reason: String) {
        self.key = key
        self.reason = reason
    }
}
