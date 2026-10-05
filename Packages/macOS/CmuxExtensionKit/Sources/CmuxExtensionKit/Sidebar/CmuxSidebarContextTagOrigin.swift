import Foundation

/// Provenance of an accepted project-context tag.
public enum CmuxSidebarContextTagOrigin: String, Codable, Equatable, Sendable {
    /// A deliberate user selection that automatic analyses must preserve.
    case manual
    /// A suggestion accepted from an analyzer.
    case automatic
}
