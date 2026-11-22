/// Order of one lease session's `automation.input` events (`seq` is gap-free
/// per lease session over published events and starts at 0). A gap means the
/// app lost events: it is reported, never skipped silently.
public struct AgentInputSequence: Sendable {
    public enum Order: Equatable, Sendable {
        /// The first event seen of the session (the app may have connected mid-session).
        case first
        /// The next event.
        case next
        /// `seq` 0 after later events: a new lease session under the same name.
        case restart
        /// `missing` events before this one never arrived.
        case gap(missing: UInt64)
        /// This or a later `seq` arrived already.
        case replay
    }

    private var expected: [String: UInt64] = [:]

    public init() {}

    /// Sessions with state (each is forgotten when it holds no lease).
    public var count: Int { expected.count }

    /// Records `seq` of `session` and says where it falls.
    public mutating func note(session: String, seq: UInt64) -> Order {
        let next = expected[session]
        expected[session] = seq &+ 1
        guard let next else { return .first }
        if seq == next { return .next }
        if seq == 0 { return .restart }
        if seq > next { return .gap(missing: seq - next) }
        expected[session] = next
        return .replay
    }

    public mutating func end(_ session: String) {
        expected[session] = nil
    }
}
