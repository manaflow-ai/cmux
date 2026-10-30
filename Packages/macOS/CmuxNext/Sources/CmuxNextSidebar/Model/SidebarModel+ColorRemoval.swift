import CmuxNextDesign
import Foundation

extension SidebarModel {
    /// The listed groups that draw a color (a palette color, a custom one, or the color a group
    /// with none stored is given): what Remove All Workspace Colors sets to no color
    /// (``GroupTint/none``). A nested group is listed once.
    public var coloredGroups: [GroupID] {
        var seen = Set<GroupID>()
        return sections.flatMap(\.nodes).compactMap { node -> GroupID? in
            guard case let .group(group) = node, group.tint != GroupTint.none, seen.insert(group.id).inserted else { return nil }
            return group.id
        }
    }
}
