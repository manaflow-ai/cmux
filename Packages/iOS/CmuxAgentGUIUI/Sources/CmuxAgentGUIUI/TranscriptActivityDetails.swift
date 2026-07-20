public import CmuxAgentGUIProjection

/// Immutable activity-detail payload presented outside the transcript flow.
public struct TranscriptActivityDetails: Hashable, Identifiable, Sendable {
    /// Stable identity of the turn whose activity is shown.
    public let turnID: TranscriptTurnID
    /// Ordered fail-open activity items and their deterministic aggregate.
    public let summary: TranscriptActivitySummary

    /// The stable sheet identity.
    public var id: TranscriptTurnID { turnID }

    /// Creates activity details for one transcript turn.
    /// - Parameters:
    ///   - turnID: Stable identity of the owning turn.
    ///   - summary: Ordered activity items and aggregate counts.
    public init(turnID: TranscriptTurnID, summary: TranscriptActivitySummary) {
        self.turnID = turnID
        self.summary = summary
    }
}
