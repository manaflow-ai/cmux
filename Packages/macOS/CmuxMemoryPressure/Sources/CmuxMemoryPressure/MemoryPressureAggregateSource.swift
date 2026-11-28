/// Identifies the source used for an aggregate process-memory sample.
public enum MemoryPressureAggregateSource: String, Equatable, Sendable {
    /// macOS reported the resource coalition's instantaneous physical footprint.
    case coalition
    /// The process tree was enumerated and summed without a coalition API.
    case descendantProcessTree
    /// Neither a complete process tree nor a coalition footprint was available.
    case unavailable
}
