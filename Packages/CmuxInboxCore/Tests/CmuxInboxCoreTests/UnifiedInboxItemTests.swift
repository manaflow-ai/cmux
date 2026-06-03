import CmuxMobileContract
import Foundation
import Testing

@testable import CmuxInboxCore

@Suite("UnifiedInboxItem")
struct UnifiedInboxItemTests {
    @Test("derives a workspace identity")
    func derivesWorkspaceID() {
        let item = UnifiedInboxItem(
            kind: .workspace,
            workspaceID: "ws-1",
            title: "Build",
            preview: "running",
            unreadCount: 2,
            sortDate: Date(timeIntervalSince1970: 0)
        )
        #expect(item.id == "workspace:ws-1")
        #expect(item.isUnread)
    }

    @Test("query match is case-insensitive across fields")
    func queryMatches() {
        let item = UnifiedInboxItem(
            kind: .conversation,
            conversationID: "c-1",
            title: "Deploy Pipeline",
            preview: "All green",
            unreadCount: 0,
            sortDate: Date(timeIntervalSince1970: 0),
            accessoryLabel: "macmini"
        )
        #expect(item.matches(query: ""))
        #expect(item.matches(query: "  "))
        #expect(item.matches(query: "deploy"))
        #expect(item.matches(query: "GREEN"))
        #expect(item.matches(query: "mini"))
        #expect(!item.matches(query: "absent"))
        #expect(!item.isUnread)
    }

    @Test("maps a mobile inbox workspace row")
    func mapsMobileRow() {
        let row = MobileInboxWorkspaceRow(
            kind: "workspace",
            workspaceId: "ws-9",
            machineId: "m-9",
            title: "Agent",
            preview: "",
            phase: "running",
            tmuxSessionName: "sess",
            lastActivityAt: 0,
            latestEventSeq: 5,
            lastReadEventSeq: 3,
            unread: true,
            unreadCount: 2,
            machineDisplayName: "Mac mini",
            machineStatus: .online,
            tailscaleHostname: "host",
            tailscaleIPs: ["100.64.0.1"]
        )
        let item = UnifiedInboxItem(workspaceRow: row, teamID: "team-1")
        #expect(item.kind == .workspace)
        #expect(item.workspaceID == "ws-9")
        #expect(item.teamID == "team-1")
        #expect(item.preview == "No recent activity")
        #expect(item.unreadCount == 2)
        #expect(item.accessoryLabel == "Mac mini")
        #expect(item.machineStatus == .online)
        #expect(item.tailscaleIPs == ["100.64.0.1"])
    }
}
