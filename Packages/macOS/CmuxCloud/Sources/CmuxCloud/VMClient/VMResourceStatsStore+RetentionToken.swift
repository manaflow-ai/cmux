extension VMResourceStatsStore {
    /// A list response's reset generation and order of acceptance.
    public struct RetentionToken: Sendable {
        public let generation: UInt64
        public let sequence: UInt64

        public init(
            generation: UInt64,
            sequence: UInt64
        ) {
            self.generation = generation
            self.sequence = sequence
        }
    }
}
