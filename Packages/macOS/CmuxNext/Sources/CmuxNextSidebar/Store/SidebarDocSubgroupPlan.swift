public import CmuxNextDesign
import Foundation

/// The `sidebar.apply` ops of "New Subgroup": a new group inside `parent`.
public nonisolated struct SidebarDocSubgroupPlan {
    /// Why no op is planned.
    public enum Refusal: Hashable, Sendable {
        case unknownGroup
        case tooDeep
    }

    /// Not planned yet.
    public let ops: [[String: Any]]? = nil
    /// Not planned yet.
    public let refusal: Refusal? = nil

    public init(parent: GroupID, id: GroupID, name: String, color: GroupColor, records: SidebarDocRecords) {}
}
