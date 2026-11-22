@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextTabs
import Testing

/// cmux2-85: dropping a screen into a screen group sent its position in the
/// whole screen bar as `add-screens-to-screen-group`'s `index`; the command
/// takes the position inside the group (cmux-tui spec commands.md, "at
/// `index` inside it").
@MainActor
struct ScreenGroupDropIndexTests {
    @Test func aDropIntoAGroupNotAtTheStartUsesTheSlotInsideTheGroup() {
        let model = TabStripModel(style: .chrome, showsNewTabButton: true)
        let group: CmuxNextTabs.TabGroupID = "g"
        model.groups = [TabGroupItem(id: group, name: "G")]
        model.tabs = [
            TabItem(id: "s0", title: "s0"), TabItem(id: "s1", title: "s1"),
            TabItem(id: "g1", title: "g1", groupID: group), TabItem(id: "g2", title: "g2", groupID: group),
        ]
        // s0 dropped between g1 and g2: bar index 2 of [s1, g1, g2] (s0 left its place).
        #expect(ScreenBarController.groupIndex(2, moving: "s0", group: group, in: model) == 1)
        // At the group's start and after its last member.
        #expect(ScreenBarController.groupIndex(1, moving: "s0", group: group, in: model) == 0)
        #expect(ScreenBarController.groupIndex(3, moving: "s0", group: group, in: model) == 2)
    }
}
