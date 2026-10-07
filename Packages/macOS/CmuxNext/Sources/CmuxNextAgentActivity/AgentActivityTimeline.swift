import Foundation

/// The event stream that contributed a row to an agent's unified timeline.
public enum AgentActivityTimelineSource: String, Sendable, Hashable {
    case browser
    case cua
    case acp
}

/// A source-neutral row used to merge browser, computer-use, and ACP activity.
public struct AgentActivityTimelineEvent: Sendable, Hashable, Identifiable {
    public let id: String
    public let agentID: String
    public let source: AgentActivityTimelineSource
    public let at: Date
    public let sequence: UInt64
    public let title: String
    public let detail: String?
    public let thumbnailBlob: String?

    public init(id: String, agentID: String, source: AgentActivityTimelineSource, at: Date,
                sequence: UInt64, title: String, detail: String? = nil, thumbnailBlob: String? = nil) {
        self.id = id
        self.agentID = agentID
        self.source = source
        self.at = at
        self.sequence = sequence
        self.title = title
        self.detail = detail
        self.thumbnailBlob = thumbnailBlob
    }
}

/// Stable ordering for a per-agent timeline assembled from independent streams.
public struct AgentActivityTimelineMerger: Sendable {
    public init() {}

    /// Merges rows by timestamp, then source, sequence, and id for deterministic ties.
    public static func merge(_ events: [AgentActivityTimelineEvent]) -> [AgentActivityTimelineEvent] {
        events.sorted {
            if $0.at != $1.at { return $0.at < $1.at }
            if $0.source.rawValue != $1.source.rawValue { return $0.source.rawValue < $1.source.rawValue }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
    }
}
