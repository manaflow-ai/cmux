/// Declares a channel: its stream name, delivery class, priority and send
/// budget.
public struct ChannelDescriptor: Sendable, Hashable {
    /// Feature-chosen stream name, for example `terminal/term_ab12`.
    public var stream: String
    public var reliability: ChannelReliability
    public var priority: ChannelPriority
    /// Reliable: the most unacknowledged bytes in flight before `send`
    /// suspends. Others: the most queued bytes before the oldest is dropped.
    public var budgetBytes: Int

    public init(
        stream: String,
        reliability: ChannelReliability,
        priority: ChannelPriority,
        budgetBytes: Int? = nil
    ) {
        self.stream = stream
        self.reliability = reliability
        self.priority = priority
        self.budgetBytes = max(1, budgetBytes ?? Self.defaultBudget(for: priority))
    }

    /// Terminal viewer credit is 256 KiB (transport.md 12a); files 4 MiB.
    public static func defaultBudget(for priority: ChannelPriority) -> Int {
        switch priority {
        case .input, .control: 64 * 1024
        case .render: 256 * 1024
        case .media: 512 * 1024
        case .bulk: 4 * 1024 * 1024
        }
    }
}
