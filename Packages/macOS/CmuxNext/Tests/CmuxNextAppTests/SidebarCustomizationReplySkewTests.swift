@testable import CmuxNextSidebar
import Foundation
import Testing

/// The app links a pinned Rust FFI (`app-ffi-pin.json`) that can be older than the Swift beside it. A planner reply
/// from a pin before #46136 has no `selection_spared`; when Swift required it, every reply failed to decode and the
/// planner returned the sidebar unchanged, so no section or workspace setting applied (gallery step 63f275eb at
/// feat-cmux-next 7453397d, pin b209afdc).
struct SidebarCustomizationReplySkewTests {
    @Test func aReplyFromAnOlderPinStillDecodes() throws {
        let older = Data("""
        {"section_order": ["projects"], "hidden_sections": ["recents"], "hidden_workspaces": ["ws-3"],
         "workspace_groups": {"ws-2": "grp"}, "workspace_orders": {"ws-2": 0}, "problems": []}
        """.utf8)
        let reply = try JSONDecoder().decode(SidebarCustomizationPlanner.Reply.self, from: older)
        #expect(reply.hiddenSections == ["recents"])
        #expect(reply.hiddenWorkspaces == ["ws-3"])
        // Unknown whether the selection is spared: the next selection change projects again, as before #46136.
        #expect(reply.selectionSpared)
    }

    @Test func aReplyThatSaysTheSelectionIsNotSparedKeepsIt() throws {
        let current = Data("""
        {"section_order": [], "hidden_sections": [], "hidden_workspaces": [], "workspace_groups": {},
         "workspace_orders": {}, "selection_spared": false}
        """.utf8)
        #expect(try !JSONDecoder().decode(SidebarCustomizationPlanner.Reply.self, from: current).selectionSpared)
    }
}
