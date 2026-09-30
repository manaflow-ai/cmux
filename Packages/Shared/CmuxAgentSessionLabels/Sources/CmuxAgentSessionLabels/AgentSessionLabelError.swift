import Foundation

/// Why a label, a key or a stored document was rejected.
public enum AgentSessionLabelError: Error, Equatable, Sendable {
    /// The label was empty, or became empty once trimmed.
    case emptyLabel
    /// The label was longer than ``AgentSessionLabel/maximumLength``.
    case labelTooLong(length: Int, maximum: Int)
    /// The label or key held a character a one-line listing cannot show honestly.
    case disallowedCharacter(scalar: Unicode.Scalar)
    /// An agent name or session id was empty.
    case emptyKeyField(field: String)
    /// The stored document could not be read as the labels file.
    ///
    /// Only cmux writes this file, and it writes it atomically, so this means a
    /// hand edit or a damaged disk. The path is part of the message because the
    /// fix is to look at it.
    case malformedStore(path: String, reason: String)
}

extension AgentSessionLabelError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyLabel:
            return "a session label cannot be empty"
        case let .labelTooLong(length, maximum):
            return "a session label is at most \(maximum) characters, got \(length)"
        case let .disallowedCharacter(scalar):
            return String(
                format: "a session label cannot contain U+%04X", scalar.value
            )
        case let .emptyKeyField(field):
            return "a session label needs a non-empty \(field)"
        case let .malformedStore(path, reason):
            return "\(path) is not a readable session label store: \(reason)"
        }
    }
}
