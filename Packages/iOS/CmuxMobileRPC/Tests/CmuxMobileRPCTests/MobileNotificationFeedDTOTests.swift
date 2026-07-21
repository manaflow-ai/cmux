import CmuxMobileRPC
import Foundation
import Testing

@Suite("Notification feed RPC DTOs")
struct MobileNotificationFeedDTOTests {
    @Test("List response decodes every navigation and display field")
    func listResponseDecode() throws {
        let data = Data(#"{"revision":17,"notifications":[{"id":"notification-1","workspace_id":"workspace-1","surface_id":"surface-1","title":"Approval needed","subtitle":"Claude Code","body":"Allow the command?","created_at":1721000000.25,"is_read":false,"retargets_to_live_surface_owner":true,"workspace_title":"cmux","surface_title":"agent"}]}"#.utf8)

        let response = try MobileNotificationFeedListResponse.decode(data)
        let item = try #require(response.notifications.first)

        #expect(response.revision == 17)
        #expect(item.id == "notification-1")
        #expect(item.workspaceID == "workspace-1")
        #expect(item.surfaceID == "surface-1")
        #expect(item.title == "Approval needed")
        #expect(item.subtitle == "Claude Code")
        #expect(item.body == "Allow the command?")
        #expect(item.createdAt == Date(timeIntervalSince1970: 1_721_000_000.25))
        #expect(item.isRead == false)
        #expect(item.retargetsToLiveSurfaceOwner)
        #expect(item.workspaceTitle == "cmux")
        #expect(item.surfaceTitle == "agent")
    }

    @Test("Missing retarget provenance stays confined")
    func missingRetargetProvenanceDefaultsToFalse() throws {
        let data = Data(#"{"revision":1,"notifications":[{"id":"notification-1","workspace_id":"workspace-1","title":"Title","body":"Body","created_at":1721000000,"is_read":true}]}"#.utf8)

        let item = try #require(MobileNotificationFeedListResponse.decode(data).notifications.first)

        #expect(!item.retargetsToLiveSurfaceOwner)
    }

    @Test("Revision-only changed event rejects malformed payloads")
    func changedEventDecode() {
        #expect(MobileNotificationFeedChangedEvent.decode(Data(#"{"revision":18}"#.utf8))?.revision == 18)
        #expect(MobileNotificationFeedChangedEvent.decode(Data(#"{"revision":"18"}"#.utf8)) == nil)
    }

    @Test("Read mutation response decodes marked count and revision")
    func mutationResponseDecode() throws {
        let response = try MobileNotificationFeedMutationResponse.decode(
            Data(#"{"marked":3,"revision":21}"#.utf8)
        )

        #expect(response.marked == 3)
        #expect(response.revision == 21)
    }
}
