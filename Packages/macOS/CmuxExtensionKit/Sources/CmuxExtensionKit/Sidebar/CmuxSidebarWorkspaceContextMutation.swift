import Foundation

/// One deliberate edit of CMUX's accepted workspace context.
public enum CmuxSidebarWorkspaceContextMutation: Codable, Equatable, Sendable {
    /// Adds or replaces a tag; CMUX forces manual provenance and replaces automatic tags in its dimension.
    case setManualTag(CmuxSidebarContextTag)
    /// Removes an accepted tag; an automatic tag is also rejected to prevent immediate reappearance.
    case removeTag(id: String)
    /// Sets or clears the accepted project summary.
    case setSummary(String?)
    /// Removes one retained former display name.
    case removeAlias(String)
    /// Suppresses stable automatic tag IDs and removes matching accepted automatic tags.
    case rejectAutomaticTags(ids: [String])
    /// Clears specified rejections, or every rejection when IDs are nil; it does not auto-accept tags.
    case clearAutomaticTagRejections(ids: [String]?)
}
