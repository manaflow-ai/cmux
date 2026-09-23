extension VMResourceStatsStore {
    /// A list response's reset generation and order of acceptance.
    struct RetentionToken: Sendable {
        let generation: UInt64
        let sequence: UInt64
    }
}
