public import CmuxAgentCursor
public import Foundation
import os

/// The provider bridge for agent inputs (agent-cursor.md section 2): each
/// `input {event}` frame from the browser host goes to the
/// `AgentCursorPublisher` of the content that owns the event's target.
/// Events are decoded and checked against schemas/automation-input; only the
/// session that holds the target's lease draws there; a seq gap is counted
/// and logged, and the newest event is still drawn (the cursor goes to the
/// newest point). The bridge owns per-session state: when a session starts
/// again or holds no lease any more, every content's publisher forgets it.
@MainActor
public final class AgentCursorInputBridge {
    public struct Counts: Equatable, Sendable {
        public var published = 0
        /// Events the schema rejects.
        public var rejected = 0
        /// Events whose target no content owns (a workspace no window holds).
        public var unrouted = 0
        /// Events of a session that does not hold the target's lease.
        public var unleased = 0
        /// Gaps, and the events they lost.
        public var gaps = 0
        public var missing: UInt64 = 0
        public var replays = 0

        public init(published: Int = 0, rejected: Int = 0, unrouted: Int = 0, unleased: Int = 0, gaps: Int = 0,
                    missing: UInt64 = 0, replays: Int = 0) {
            self.published = published
            self.rejected = rejected
            self.unrouted = unrouted
            self.unleased = unleased
            self.gaps = gaps
            self.missing = missing
            self.replays = replays
        }
    }

    public private(set) var counts = Counts()
    private var sequence = AgentInputSequence()
    /// Which sessions still hold a lease (lease frames).
    private var leases = AgentCursorLeaseRouter()
    /// The session that holds each target's lease.
    private var holders: [String: String] = [:]
    private let publisher: (String) -> AgentCursorPublisher?
    private let publishers: () -> [AgentCursorPublisher]
    private static let log = Logger(subsystem: "com.cmux.next", category: "agent-cursor-input")

    /// - Parameters:
    ///   - publisher: The publisher of the content that owns a target id, or nil.
    ///   - publishers: Every content's publisher (shown and parked).
    public init(publisher: @escaping (_ targetID: String) -> AgentCursorPublisher?,
                publishers: @escaping () -> [AgentCursorPublisher]) {
        self.publisher = publisher
        self.publishers = publishers
    }

    /// Sessions with sequence state (diagnostics, tests).
    public var trackedSessions: Int { sequence.count }

    /// One `input` frame's event (its JSON).
    public func receive(_ data: Data) {
        let event: AutomationInputEvent
        do {
            event = try AutomationInputEvent.decode(data)
        } catch {
            counts.rejected += 1
            Self.log.error("automation.input rejected: \(String(describing: error), privacy: .public)")
            return
        }
        guard holders[event.targetID] == event.sessionID else {
            counts.unleased += 1
            return
        }
        let order = sequence.note(session: event.sessionID, seq: event.seq)
        switch order {
        case .first, .next, .restart:
            break
        case .gap(let missing):
            counts.gaps += 1
            counts.missing = counts.missing.addingReportingOverflow(missing).overflow ? .max : counts.missing + missing
            Self.log.error("automation.input gap: session \(event.sessionID, privacy: .public) lost \(missing) event(s) before seq \(event.seq)")
        case .replay:
            counts.replays += 1
            return
        }
        guard let owner = publisher(event.targetID) else {
            counts.unrouted += 1
            return
        }
        // A session that starts again (seq 0 after later events) replaces the
        // older one of that name in every publisher, which would refuse its seq.
        if order == .restart { forget(event.sessionID) }
        owner.publish(event)
        counts.published += 1
    }

    /// A lease frame (`observeLeases`): a session that holds no lease any
    /// more loses its sequence state.
    public func leaseChanged(target: String, session: String?, wireState: String?) {
        holders[target] = session
        for update in leases.leaseChanged(target: target, session: session, wireState: wireState) where update.state == nil {
            forget(update.session)
        }
    }

    /// Drops a session's state here and in every content's publisher.
    private func forget(_ session: String) {
        sequence.end(session)
        for publisher in publishers() { publisher.endSession(session) }
    }
}
