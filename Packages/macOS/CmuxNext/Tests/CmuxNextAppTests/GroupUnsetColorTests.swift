import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20: "what's up with the grouping colors? We have different grouping colors."
/// Groups an agent or the CLI made store no color, and every one of them drew the same grey
/// header. A group with no stored color draws a palette color picked from its id, stable
/// across launches; a group someone colored keeps its color, grey included.
@MainActor
struct GroupUnsetColorTests {
    private static func group(_ id: String, color: String?) -> CmuxNextSidebar.SidebarGroup? {
        let model = WorkspaceGroupModel(WorkspaceGroupSnapshot(id: WorkspaceGroupID(rawValue: id), name: id, color: color))
        let sections = SidebarMapping.shared.sections([CmuxNextDaemon.SidebarSection(group: model, workspaces: [])],
                                                      machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
        for node in sections.flatMap(\.nodes) {
            if case let .group(group) = node { return group }
        }
        return nil
    }

    @Test func groupWithNoColorDrawsAPaletteColor() throws {
        // Leo's five groups on 2026-10-20, all made with no color.
        let ids = ["grp_2916936ea9914e6ca942a58b5f96a2e7", "grp_8cd4b80f3586401c86f6b643dc46342e",
                   "grp_b5bc88b3a38943bc9d7e52efdda7373c", "grp_04b41a66461645dba9ba21c4a96be948",
                   "grp_47582f707ae84101807771fa7b4ad71e"]
        let colors = try ids.map { try #require(Self.group($0, color: nil)).tint }
        #expect(!colors.contains(.palette(.grey)), "a group with no color is not grey")
        #expect(!colors.contains(.palette(.blue)), "the app never picks blue by itself")
        #expect(Set(colors).count > 1, "groups with no color do not all share one color")
        // Stable: the same group maps to the same color every time.
        #expect(try ids.map { try #require(Self.group($0, color: nil)).tint } == colors)
        // Stable across launches too (no per-process seeded hash): a fixed id, a fixed color.
        #expect(GroupColor.unset(id: ids[0]) == .yellow)
        #expect(colors == ids.map { .palette(GroupColor.unset(id: $0)) })
    }

    @Test func storedColorsAreKept() throws {
        #expect(try #require(Self.group("grp_a", color: "grey")).tint == .palette(.grey))
        #expect(try #require(Self.group("grp_a", color: "green")).tint == .palette(.green))
        #expect(try #require(Self.group("grp_a", color: "#336699")).tint == GroupTint(wire: "#336699"))
    }
}
