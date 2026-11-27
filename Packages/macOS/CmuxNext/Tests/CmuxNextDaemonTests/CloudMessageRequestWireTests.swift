import Foundation
import Testing
@testable import CmuxNextDaemon

/// Message requests on the wire (plans/cmux-next/home-messaging-invites/DESIGN.md 2.3): the
/// daemon's `cloud-requests-list` read and the two answers sent through `cloud-conversation-op`.
struct CloudMessageRequestWireTests {
    @Test func theListSendsNoFields() throws {
        let data = try WireCoding.encodeRequest(CloudMessageRequestsRequest(), id: 3)
        let fields = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(fields == .object(["id": .number(3), "cmd": .string("cloud-requests-list")]))
    }

    @Test func aRequestDecodesWithoutAnyAddressID() throws {
        let line = Data(#"""
        {"id":3,"ok":true,"data":{"requests":[{"conversation":"conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS","inviter":"Lawrence Chen","kind":"dm","preview":"hi","created_at":"2026-10-13T18:00:00.000Z","expires_at":"2026-10-27T18:00:00.000Z","trusted":true},{"conversation":"conv_0Y05MEWEFMQQB63VDHQB9MXAJT","inviter":"Frank","kind":"group","title":"Lunch","preview":"","created_at":"2026-10-14T18:00:00.000Z","expires_at":"2026-10-28T18:00:00.000Z","trusted":false}]}}
        """#.utf8)
        let list = try WireCoding.decodeResponse(CloudMessageRequestsRequest.Response.self, from: line)
        #expect(list.requests.count == 2)
        let dm = try #require(list.requests.first)
        #expect(dm.conversation == "conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS")
        #expect(dm.inviter == "Lawrence Chen")
        #expect(dm.isGroup == false)
        #expect(dm.title == nil)
        #expect(dm.preview == "hi")
        #expect(dm.trusted)
        #expect(dm.createdAt == ISO8601DateFormatter.fractional.date(from: "2026-10-13T18:00:00.000Z"))
        let group = list.requests[1]
        #expect(group.isGroup)
        #expect(group.title == "Lunch")
    }

    @Test func acceptAndDismissAreCloudOps() throws {
        let accept = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encoder().encode(CloudConversationOp.acceptRequest))
        #expect(accept == .object(["kind": .string("invite.accept_verified")]))
        let block = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encoder().encode(CloudConversationOp.dismissRequest(block: true)))
        #expect(block == .object(["kind": .string("request.dismiss"), "block": .bool(true)]))
        let decline = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encoder().encode(CloudConversationOp.dismissRequest(block: false)))
        #expect(decline == .object(["kind": .string("request.dismiss"), "block": .bool(false)]))
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
