public import CmuxMobileWire

/// The owner's decision on one op.
public enum OpOutcome: Hashable, Sendable {
    case applied(ResultFrame)
    case rejected(RejectFrame)
}
