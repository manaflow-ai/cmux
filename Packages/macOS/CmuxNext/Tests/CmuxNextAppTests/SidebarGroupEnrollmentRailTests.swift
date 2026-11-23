import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-08, on Chrome's tab groups: "you look at how the groups move new tabs in and out of them ... that group
/// enrollment animation is really nice". While a held row's slot joins a group, the group's rail reaches over the slot
/// (`SidebarGroupLine.lines(enrolling:)`), so the rail takes the row in on the rows' spring and lets it go when the slot
/// leaves; an empty group's rail grows out of its header. The list is `SidebarGroupDragRailTests`': loose `scratch`,
/// Work (`docs`, `web`, `api`), Infra (`deploy`), an empty group.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupEnrollmentRailTests {
    typealias G = SidebarGroupDragRailTests

    static func line(_ list: SidebarListView, _ group: GroupID, enrolling: (group: GroupID, bottom: CGFloat)?) -> CGRect? {
        SidebarGroupLine.lines(list.displayed.rows, colors: list.groups, enrolling: enrolling) { list.frame(for: $0) }
            .first { $0.group == group }?.frame
    }

    @Test func aSlotAtAGroupsEndStretchesItsRailOverTheSlot() throws {
        let (list, window) = G.list(G.Drops())
        defer { window.close() }
        let api = try #require(list.displayed.row(for: .workspace(WorkspaceID("api"))))
        let resting = try #require(Self.line(list, G.work, enrolling: nil), "Work has no rail")
        #expect(abs(resting.maxY - list.frame(for: api).maxY) < 0.5, "Work's rail does not end at its last member")
        let slotBottom = list.frame(for: api).maxY + api.height
        let enrolled = try #require(Self.line(list, G.work, enrolling: (G.work, slotBottom)))
        #expect(abs(enrolled.maxY - slotBottom) < 0.5, "the rail ends at \(enrolled.maxY), not over the slot at \(slotBottom)")
        #expect(enrolled.minY == resting.minY && enrolled.minX == resting.minX, "the rail moved its top or x: \(enrolled) from \(resting)")
        // Another group's slot leaves Work's rail alone.
        #expect(Self.line(list, G.work, enrolling: (G.infra, slotBottom + 200)) == resting)
    }

    @Test func aSlotInAnEmptyGroupGrowsARailOutOfItsHeader() throws {
        let (list, window) = G.list(G.Drops())
        defer { window.close() }
        let header = try #require(list.displayed.row(for: .group(G.empty)))
        #expect(Self.line(list, G.empty, enrolling: nil) == nil, "an empty group drew a rail")
        let slotBottom = list.frame(for: header).maxY + header.height
        let grown = try #require(Self.line(list, G.empty, enrolling: (G.empty, slotBottom)), "the slot drew no rail in the empty group")
        #expect(grown.minY >= list.frame(for: header).maxY, "the rail starts inside its header bar")
        #expect(abs(grown.maxY - slotBottom) < 0.5, "the rail ends at \(grown.maxY), not over the slot at \(slotBottom)")
    }

    @Test func aRailNeverShrinksForASlotAboveItsEnd() throws {
        let (list, window) = G.list(G.Drops())
        defer { window.close() }
        let docs = try #require(list.displayed.row(for: .workspace(WorkspaceID("docs"))))
        let resting = try #require(Self.line(list, G.work, enrolling: nil))
        #expect(Self.line(list, G.work, enrolling: (G.work, list.frame(for: docs).maxY)) == resting)
    }
}
