import Foundation

/// An analyzed proposal retained by CMUX until the user accepts or rejects it.
/// Conversation IDs are exact metadata identifiers; no transcript is transported.
public struct CmuxSidebarWorkspaceContextProposal: Codable, Equatable, Identifiable, Sendable {
    /// Unique identity of this analysis, used to reject a stale acceptance.
    public var id: UUID
    /// Suggested tags; CMUX normalizes their origin to automatic.
    public var suggestedTags: [CmuxSidebarContextTag]
    /// Suggested workspace title, never applied merely by storing the proposal.
    public var suggestedTitle: String?
    /// Suggested concise project summary.
    public var summary: String?
    /// Declared analyzer source.
    public var source: String
    /// Fingerprint of the exact source material analyzed.
    public var sourceFingerprint: String
    /// Exact conversation identifiers used by the analyzer.
    public var conversationIDs: [String]
    /// Time the analyzer produced this proposal.
    public var analyzedAt: Date

    /// Creates a proposal without applying any accepted metadata.
    /// - Parameters:
    ///   - id: Analysis identity.
    ///   - suggestedTags: Candidate classification tags.
    ///   - suggestedTitle: Candidate title, or nil.
    ///   - summary: Candidate summary, or nil.
    ///   - source: Analyzer provenance label.
    ///   - sourceFingerprint: Fingerprint bound to the analyzed material.
    ///   - conversationIDs: Exact analyzed conversation IDs.
    ///   - analyzedAt: Analysis completion time.
    public init(id: UUID = UUID(), suggestedTags: [CmuxSidebarContextTag], suggestedTitle: String? = nil, summary: String? = nil, source: String, sourceFingerprint: String, conversationIDs: [String], analyzedAt: Date) {
        self.id = id
        self.suggestedTags = suggestedTags
        self.suggestedTitle = suggestedTitle
        self.summary = summary
        self.source = source
        self.sourceFingerprint = sourceFingerprint
        self.conversationIDs = conversationIDs
        self.analyzedAt = analyzedAt
    }
}
