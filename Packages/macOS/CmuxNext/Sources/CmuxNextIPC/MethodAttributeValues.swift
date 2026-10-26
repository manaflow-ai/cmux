// The enumerated method attributes of the schema (MethodTable.swift).

/// The schema `priority`: which outbound queue and which pool workers serve
/// the method. Raw values equal the frame header's priority hint byte.
public enum MethodPriority: UInt8, Sendable, CaseIterable {
    case input = 0
    case control = 1
    case bulk = 2
    case background = 3

    /// The schema spelling.
    public var schemaName: String {
        switch self {
        case .input: "input"
        case .control: "control"
        case .bulk: "bulk"
        case .background: "background"
        }
    }
}

/// The schema `ordering`: the connection or stream sequence, or a reviewed
/// read-only read that may run beside it.
public enum MethodOrdering: Sendable, CaseIterable {
    case sequence
    case independent

    /// The schema spelling.
    public var schemaName: String {
        switch self {
        case .sequence: "sequence"
        case .independent: "independent"
        }
    }
}

/// The schema `durability`: what the reply waits for. Every framed command
/// states it; there is no default.
public enum MethodDurability: Sendable, CaseIterable {
    case readOnly
    case memory
    case replyBeforeJournal
    case replyAfterJournal

    /// The schema spelling.
    public var schemaName: String {
        switch self {
        case .readOnly: "read_only"
        case .memory: "memory"
        case .replyBeforeJournal: "reply_before_journal"
        case .replyAfterJournal: "reply_after_journal"
        }
    }
}
