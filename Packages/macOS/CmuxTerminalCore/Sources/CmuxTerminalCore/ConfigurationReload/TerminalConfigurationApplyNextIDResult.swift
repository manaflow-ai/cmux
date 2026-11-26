/// The result of one bounded pull from a fixed terminal-surface traversal.
public enum TerminalConfigurationApplyNextIDResult<ID> {
    /// A live identity is ready to apply.
    case id(ID)

    /// One released or otherwise skipped registration was consumed.
    case skipped

    /// The fixed traversal has reached its endpoint.
    case exhausted
}
