@testable import CmuxNextApp
import Foundation
import Testing

/// What a cloud group link opens on this Mac (CloudGroupLink.plan, cloud-groups-DESIGN.md slice 1):
/// the named workspace when it is in the group and open here, else the group's first workspace
/// (by position) open here; a group with none open here says so; an unreadable group is gone.
struct CloudGroupLinkPlanTests {
    private static let reply: [String: Any] = [
        "group": ["id": "grp_f9a917b1721deb93e834", "name": "Fix login"],
        "items": [
            ["workspace": "ws_b", "position": 1],
            ["workspace": "ws_a", "position": 0],
            ["workspace": "ws_c", "position": 2]
        ]
    ]

    @Test func theFirstWorkspaceOpenHereByPositionIsShown() {
        #expect(CloudGroupLink.plan(reply: Self.reply, named: nil) { $0 != "ws_a" } == .reveal("ws_b"))
        #expect(CloudGroupLink.plan(reply: Self.reply, named: nil) { _ in true } == .reveal("ws_a"))
    }

    @Test func theNamedWorkspaceWinsWhenItIsInTheGroupAndOpen() {
        #expect(CloudGroupLink.plan(reply: Self.reply, named: "ws_c") { _ in true } == .reveal("ws_c"))
        // Named but not in the group: never opened on the link's word.
        #expect(CloudGroupLink.plan(reply: Self.reply, named: "ws_z") { _ in true } == .reveal("ws_a"))
    }

    @Test func noneOpenHereAndGoneAreDifferent() {
        #expect(CloudGroupLink.plan(reply: Self.reply, named: nil) { _ in false } == .notOpenHere)
        #expect(CloudGroupLink.plan(reply: nil, named: nil) { _ in true } == .gone)
        #expect(CloudGroupLink.plan(reply: ["items": []], named: nil) { _ in true } == .gone)
    }
}
