/// cmux presentation category for a provider-owned agent status.
public enum NestedStatusPresentation: String, Codable, Sendable {
    /// Agent is actively performing work.
    case working

    /// Agent is available but not actively working.
    case idle

    /// Agent requires attention before work can continue.
    case blocked

    /// Agent completed its current work.
    case done

    /// Provider state has no known cmux presentation mapping.
    case unknown
}
