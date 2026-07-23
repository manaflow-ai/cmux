import Foundation

/// Orders transcript artifact references so completed capture work advances monotonically.
struct AgentArtifactReferenceCursor: Comparable, Sendable {
    let sequence: Int
    let path: String

    static func < (lhs: AgentArtifactReferenceCursor, rhs: AgentArtifactReferenceCursor) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.path < rhs.path
    }
}
