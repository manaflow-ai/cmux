import Foundation

/// Why a label, a key or a stored document was rejected.
///
/// Every case renders through ``description``, so a CLI can print one sentence
/// rather than an `NSError` dump. Failures that reach the file system are wrapped
/// here for the same reason.
public enum AgentSessionLabelError: Error, Equatable, Sendable {
    /// The label was empty, or became empty once trimmed.
    case emptyLabel
    /// The label was longer than ``AgentSessionLabel/maximumLength``.
    case labelTooLong(length: Int, maximum: Int)
    /// The label held more UTF-8 bytes than ``AgentSessionLabel/maximumByteCount``.
    case labelTooManyBytes(bytes: Int, maximum: Int)
    /// The label or key held a character a one-line listing cannot show honestly.
    case disallowedCharacter(scalar: Unicode.Scalar)
    /// An agent name or session id was empty.
    case emptyKeyField(field: String)
    /// An agent name or session id was longer than
    /// ``AgentSessionLabelKey/maximumFieldLength``.
    case keyFieldTooLong(field: String, length: Int, maximum: Int)
    /// A record is stored under a key this build would never write, so no
    /// command could address it.
    ///
    /// The store writes trimmed keys and looks records up by the trimmed form,
    /// so a record filed under `"codex "` cannot be read back, replaced or
    /// cleared through any key a caller can build. Reporting it is the only
    /// honest answer: trimming it on the way out would return a label that the
    /// next write does not update and the next clear does not remove.
    case unaddressableRecord(field: String)
    /// The stored document could not be read as the labels file.
    ///
    /// The reachable causes are a hand edit, a truncation, a version this build
    /// does not write, and a timestamp in a form this build does not read. The
    /// path is part of the message because the fix is to look at it.
    case malformedStore(path: String, reason: String)
    /// The store file exists but could not be read.
    ///
    /// Separate from ``malformedStore(path:reason:)`` because the content is not
    /// the problem: the usual causes are a permission the process does not have
    /// and a directory where the file should be.
    case unreadableFile(path: String, reason: String)
    /// The store file could not be written.
    case unwritableFile(path: String, reason: String)
}

extension AgentSessionLabelError: CustomStringConvertible {
    /// One sentence a command line can print as it is.
    public var description: String {
        switch self {
        case .emptyLabel:
            return "a session label cannot be empty"
        case let .labelTooLong(length, maximum):
            return "a session label is at most \(maximum) characters, got \(length)"
        case let .labelTooManyBytes(bytes, maximum):
            return "a session label is at most \(maximum) bytes, got \(bytes)"
        case let .disallowedCharacter(scalar):
            return String(
                format: "a session label cannot contain U+%04X", scalar.value
            )
        case let .emptyKeyField(field):
            return "a session label needs a non-empty \(field)"
        case let .keyFieldTooLong(field, length, maximum):
            return "a session label's \(field) is at most \(maximum) characters, got \(length)"
        case let .unaddressableRecord(field):
            return "a session label's \(field) is stored with surrounding "
                + "whitespace, so no command could address this record"
        case let .malformedStore(path, reason):
            return "\(path) is not a readable session label store: \(reason)"
        case let .unreadableFile(path, reason):
            return "\(path) could not be read: \(reason)"
        case let .unwritableFile(path, reason):
            return "\(path) could not be written: \(reason)"
        }
    }
}
