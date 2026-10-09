/// Send priority. The session's pump always sends the highest priority
/// queued frame first: input > control > render > media > bulk.
public enum ChannelPriority: Int, Sendable, Hashable, CaseIterable, Comparable {
    case input = 0
    case control = 1
    case render = 2
    case media = 3
    case bulk = 4

    public static func < (lhs: ChannelPriority, rhs: ChannelPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
