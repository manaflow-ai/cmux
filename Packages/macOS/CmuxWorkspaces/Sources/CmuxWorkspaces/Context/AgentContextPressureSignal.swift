/// The kind of context-pressure evidence emitted by a provider.
public enum AgentContextPressureSignal: String, Codable, Hashable, Sendable {
    /// A provider explicitly warns that a long thread or repeated compaction harms accuracy.
    case longThreadWarning
    /// A provider reports that the context window is nearly exhausted.
    case contextLow
    /// Multiple automatic compactions indicate a sustained pressure condition.
    case repeatedAutoCompaction
}
