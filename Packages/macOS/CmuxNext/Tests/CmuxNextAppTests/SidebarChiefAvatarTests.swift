import AppKit
import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextHome
import Foundation
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextAgentLanes
import Testing

/// Leo: "they even show chief-operated chats". Ownership comes from the existing acpmux tags.
@MainActor @Suite(.serialized) struct SidebarChiefAvatarTests {
    private func lane(_ id: String, tags: [String: String] = [:], title: String = "Chat") throws -> AgentActivityLane {
        try #require(AgentActivityLane.of(summary: ["sessionId": id, "name": title, "tags": tags, "lane": ["state": "idle"]]))
    }

    /// "why does my sidebar have this CH thing": no chosen face, no mark on the row.
    @Test func aChiefWithNoChosenFaceDrawsNoMonogramOnTheRow() throws {
        #expect(SidebarChiefAvatar(home: nil) == nil)
        #expect(SidebarChiefAvatar(home: .text("🦊")) == .text("🦊"))
        let url = try #require(URL(string: "file:///tmp/face.png"))
        #expect(SidebarChiefAvatar(home: .picture(url)) == .picture(url))
    }

    @Test func namedChiefIdentityComesFromTagsAndDisappearsWhenOwnershipIsRemoved() throws {
        let lanes = AgentLaneStore()
        lanes.lanes = ["turn": try lane("turn", tags: ["mux.children": "optchat-chief:home", "cmux.chief.participant": "agent_scout"])]
        #expect(lanes.chiefParticipants["optchat-chief:home"] == "agent_scout")
        lanes.lanes["turn"] = try lane("turn", title: "Chief Scout")
        #expect(lanes.chiefParticipants.isEmpty, "a Chief-like name does not establish ownership")
    }

    @Test func onlyTheOwnedChatGetsItsChiefsFaceEvenWithLaneStatusOff() throws {
        let fixture = try SidebarLaneStatusTests.Fixture()
        fixture.lanes.lanes["chief-turn"] = try lane("chief-turn", tags: ["mux.children": "optchat-chief:home", "cmux.chief.participant": "agent_scout"])
        fixture.lanes.lanes["s-idle"] = try lane("s-idle", tags: ["mux.parent": "optchat-chief:home"])
        fixture.lanes.lanes["s-working"] = try lane("s-working", title: "Chief-controlled chat")
        SidebarLaneStatusTests.withLaneStatus(false) {
            let source = SidebarLaneStatus.applying(nil, lanes: fixture.lanes, turns: fixture.turns, chiefLanes: AgentLaneStore(),
                                                   chiefAvatar: { .text($0) })
            let sections = SidebarMapping.shared.sections(fixture.store.sidebarSections,
                machine: SidebarMachine(id: .local, name: "This Mac", kind: .local), rowSource: source)
            let rows = sections.flatMap(\.workspaces)
            #expect(rows.first { $0.title == "idle" }?.chiefAvatar == .text("agent_scout"))
            #expect(rows.filter { $0.title != "idle" }.allSatisfy { $0.chiefAvatar == nil })
        }
    }

    @Test(arguments: SidebarRowBadgeStyle.allCases)
    func avatarSharesTheColumnAndKeepsUnreadAndHoverControls(_ style: SidebarRowBadgeStyle) throws {
        try SidebarRowCloseSpotTests.withCloseSpot(.end) {
            let (model, sidebar, window) = SidebarRowCloseSpotTests.sidebar()
            defer { window.close() }
            var workspace = SidebarWorkspace(id: SidebarRowCloseSpotTests.shown, title: "Chief task", unread: .dot)
            workspace.chiefAvatar = .text("SC")
            model.sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(workspace)])]
            model.rowBadgeStyle = style
            sidebar.list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            let row = try #require(sidebar.list.rowViews[.workspace(workspace.id)] as? WorkspaceRowView)
            row.isHovered = false
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            #expect(!row.chiefMark.isHidden)
            #expect(abs(row.chiefMark.frame.midX - SidebarStyle.trailingColumnCenterX(rowWidth: row.bounds.width)) < 0.5)
            let status = style == .trailing ? row.badge as NSView : row.rowBadge
            #expect(!status.isHidden)
            #expect(!status.frame.intersects(row.chiefMark.frame), "the unread dot is retained beside the Chief")
            #expect(row.accessibilityLabel()?.contains("Operated by Chief") == true)
            row.onClose = {}
            row.onMore = {}
            row.isHovered = true
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            #expect(row.chiefMark.alphaValue == 0)
            #expect(abs(row.closeButton.frame.midX - row.chiefMark.frame.midX) < 0.5)
        }
    }

    @Test func workingSpinnerStaysInTheSlotBesideChief() throws {
        let (model, sidebar, window) = SidebarRowCloseSpotTests.sidebar()
        defer { window.close() }
        var workspace = SidebarWorkspace(id: SidebarRowCloseSpotTests.shown, title: "Chief task")
        workspace.activity = .working
        workspace.agentWorking = true
        workspace.chiefAvatar = .text("SC")
        model.sections = [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [.workspace(workspace)])]
        model.rowBadgeStyle = .trailing
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let row = try #require(sidebar.list.rowViews[.workspace(workspace.id)] as? WorkspaceRowView)
        row.isHovered = false
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        #expect(row.activity.showsGlyph)
        // statusGlyphFrame rounds to the nearest backing pixel (including the half-pixel tie).
        #expect(abs(row.activity.frame.midX - (row.chiefMark.frame.midX - SidebarStyle.trailingSlotPitch)) <= 0.5 / window.backingScaleFactor)
        #expect(!row.activity.frame.intersects(row.chiefMark.frame))
    }

}
