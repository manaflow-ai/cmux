import Foundation

/// Accepted workspace context owned and persisted by CMUX.
public struct CmuxSidebarWorkspaceContext: Codable, Equatable, Sendable {
    /// Monotonic native revision required by every context mutation.
    public var revision: UInt64
    /// Accepted classification tags, with manual selections preserved.
    public var tags: [CmuxSidebarContextTag]
    /// Previous workspace display names retained for discovery.
    public var aliases: [String]
    /// Accepted concise project summary.
    public var summary: String?
    /// Stable automatic tag IDs suppressed until explicitly cleared.
    public var rejectedAutomaticTagIDs: [String]
    /// Exact analyzed-source fingerprints suppressed after an explicit proposal rejection.
    public var rejectedSourceFingerprints: [String]
    /// Latest analyzed proposal, which is separate from accepted metadata.
    public var analyzedProposal: CmuxSidebarWorkspaceContextProposal?
    /// Whether native one-step undo is available at this revision.
    public var canUndo: Bool

    /// Creates a workspace-context value.
    /// - Parameters:
    ///   - revision: Current native revision.
    ///   - tags: Accepted tags.
    ///   - aliases: Former display names.
    ///   - summary: Accepted summary.
    ///   - rejectedAutomaticTagIDs: Suppressed automatic tag identifiers.
    ///   - analyzedProposal: Latest retained analysis.
    ///   - canUndo: Whether the host retains a reversible change.
    ///   - rejectedSourceFingerprints: Explicitly rejected source material, empty for older hosts.
    public init(revision: UInt64 = 0, tags: [CmuxSidebarContextTag] = [], aliases: [String] = [], summary: String? = nil, rejectedAutomaticTagIDs: [String] = [], analyzedProposal: CmuxSidebarWorkspaceContextProposal? = nil, canUndo: Bool = false, rejectedSourceFingerprints: [String] = []) {
        self.revision = revision
        self.tags = tags
        self.aliases = aliases
        self.summary = summary
        self.rejectedAutomaticTagIDs = rejectedAutomaticTagIDs
        self.rejectedSourceFingerprints = rejectedSourceFingerprints
        self.analyzedProposal = analyzedProposal
        self.canUndo = canUndo
    }

    /// Decodes older native contexts without inventing proposal rejections.
    /// - Parameter decoder: Native snapshot or persistence decoder.
    /// - Throws: A decoding error for malformed context fields.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            revision: try values.decode(UInt64.self, forKey: .revision),
            tags: try values.decode([CmuxSidebarContextTag].self, forKey: .tags),
            aliases: try values.decode([String].self, forKey: .aliases),
            summary: try values.decodeIfPresent(String.self, forKey: .summary),
            rejectedAutomaticTagIDs: try values.decode([String].self, forKey: .rejectedAutomaticTagIDs),
            analyzedProposal: try values.decodeIfPresent(CmuxSidebarWorkspaceContextProposal.self, forKey: .analyzedProposal),
            canUndo: try values.decode(Bool.self, forKey: .canUndo),
            rejectedSourceFingerprints: try values.decodeIfPresent([String].self, forKey: .rejectedSourceFingerprints) ?? []
        )
    }
}
