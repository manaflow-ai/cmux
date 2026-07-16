import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileNotificationFeedItemTests {
    @Test func decodesFullPayload() throws {
        let response = try MobileNotificationListResponse.decode(Data("""
        {"notifications":[{"id":"11111111-1111-1111-1111-111111111111","workspace_id":"22222222-2222-2222-2222-222222222222","surface_id":"33333333-3333-3333-3333-333333333333","title":"Done","subtitle":"Agent","body":"Tests passed","created_at":1700000000.5,"is_read":false,"workspace_name":"cmux"}],"unread_count":1}
        """.utf8))
        let item = try #require(response.items.first)
        #expect(item.id.uuidString.lowercased() == "11111111-1111-1111-1111-111111111111")
        #expect(item.surfaceID?.uuidString.lowercased() == "33333333-3333-3333-3333-333333333333")
        #expect(item.title == "Done")
        #expect(item.createdAt.timeIntervalSince1970 == 1_700_000_000.5)
        #expect(response.unreadCount == 1)
    }

    @Test func decodesPartialPayloadWithOptionalAndTextDefaults() throws {
        let response = try MobileNotificationListResponse.decode(Data("""
        {"notifications":[{"id":"11111111-1111-1111-1111-111111111111","workspace_id":"22222222-2222-2222-2222-222222222222","created_at":1700000000,"is_read":true}],"unread_count":0}
        """.utf8))
        let item = try #require(response.items.first)
        #expect(item.surfaceID == nil)
        #expect(item.workspaceName == nil)
        #expect(item.title.isEmpty && item.subtitle.isEmpty && item.body.isEmpty)
    }

    @Test func skipsMalformedItemsWithoutRejectingValidSiblings() throws {
        let response = try MobileNotificationListResponse.decode(Data("""
        {"notifications":[{"id":"not-a-uuid","workspace_id":"22222222-2222-2222-2222-222222222222","created_at":1,"is_read":false},"malformed",{"id":"11111111-1111-1111-1111-111111111111","workspace_id":"22222222-2222-2222-2222-222222222222","surface_id":"bad","created_at":2,"is_read":false},{"id":"33333333-3333-3333-3333-333333333333","workspace_id":"44444444-4444-4444-4444-444444444444","created_at":3,"is_read":true}],"unread_count":7}
        """.utf8))
        #expect(response.items.map { $0.id.uuidString.lowercased() } == ["33333333-3333-3333-3333-333333333333"])
        #expect(response.unreadCount == 7)
    }
}
