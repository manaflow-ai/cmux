import Foundation

/// Everything one read of the store found.
///
/// The labels and the records that could not be read come back together because
/// one bad record must not hide the rest: the file holds every agent's labels, so
/// throwing on the first unreadable record would blank a whole sidebar over one
/// row. A caller that only wants the good rows uses
/// ``AgentSessionLabelStore/labels()``; one that reports problems reads
/// ``unreadableRecords`` as well.
public struct AgentSessionLabelSnapshot: Sendable, Equatable {
    /// A record that is in the file but is not a label this build accepts.
    ///
    /// The usual cause is a rule that changed after the record was written, since
    /// the document's version tracks its shape and not the rules.
    public struct UnreadableRecord: Sendable, Equatable {
        /// The agent the record was filed under, as it appears in the file.
        public let agent: String
        /// The session id the record was filed under, as it appears in the file.
        public let sessionID: String
        /// Why it was skipped, in one sentence.
        public let reason: String

        public init(agent: String, sessionID: String, reason: String) {
            self.agent = agent
            self.sessionID = sessionID
            self.reason = reason
        }

        /// `agent/session id: reason`, for a line in a diagnostic.
        public var summary: String { "\(agent)/\(sessionID): \(reason)" }
    }

    /// The labels the file holds, keyed by the session each one names.
    public let labels: [AgentSessionLabelKey: AgentSessionLabel]
    /// The records that were skipped, ordered by agent and then session id.
    public let unreadableRecords: [UnreadableRecord]

    public init(
        labels: [AgentSessionLabelKey: AgentSessionLabel],
        unreadableRecords: [UnreadableRecord] = []
    ) {
        self.labels = labels
        self.unreadableRecords = unreadableRecords
    }

    /// The one order skipped records are reported in: agent, then session id.
    ///
    /// A caller prints these, and they arrive from a dictionary, so without an
    /// order the same broken file reports its rows differently from read to
    /// read. It is a function of its own so a test can hand it records that are
    /// definitely out of order: a test that goes through a file only sees
    /// whatever order that file's dictionary happened to produce.
    static func ordered(_ records: [UnreadableRecord]) -> [UnreadableRecord] {
        records.sorted { ($0.agent, $0.sessionID) < ($1.agent, $1.sessionID) }
    }
}
