import Foundation
import Testing
@testable import CmuxCloud

@Suite("teams client wire types")
struct TeamsClientModelsTests {
    private let detailJSON = """
    {
      "team": { "id": "11111111-1111-4111-8111-111111111111", "displayName": "Acme", "profileImageUrl": null },
      "viewer": {
        "userId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "role": "admin",
        "permissions": {
          "updateTeam": true, "deleteTeam": true, "inviteMembers": true, "readMembers": true,
          "removeMembers": true, "manageApiKeys": true, "manageBilling": true
        }
      },
      "members": [
        { "userId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "displayName": "Ada", "email": "ada@example.com",
          "profileImageUrl": null, "role": "admin", "isViewer": true },
        { "userId": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "displayName": null, "email": "bob@example.com",
          "profileImageUrl": null, "role": "member", "isViewer": false }
      ],
      "invitations": [
        { "id": "inv-1", "email": "carol@example.com", "role": "member", "expiresAt": "2026-10-05T12:00:00.000Z" }
      ],
      "links": [
        { "id": "link-1", "role": "member", "createdAt": "2026-09-28T12:00:00.000Z",
          "createdByUserId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "expiresAt": null, "maxUses": 5, "useCount": 2 }
      ],
      "billing": { "planId": "pro", "seats": null, "memberLimit": 3, "memberCount": 2, "hasActiveSubscription": true }
    }
    """

    @Test("decodes a team detail and derives seat usage")
    func decodesDetail() throws {
        let detail = try TeamsClient.decoder.decode(CloudTeamDetail.self, from: Data(detailJSON.utf8))
        #expect(detail.team.displayName == "Acme")
        #expect(detail.canInvite)
        #expect(detail.members.map(\.label) == ["Ada", "bob@example.com"])
        #expect(detail.invitations.first?.email == "carol@example.com")
        #expect(detail.links.first?.useCount == 2)
        // Two members plus one pending invitation fill a three-seat Pro team.
        #expect(detail.openSeats == 0)
    }

    @Test("uncapped teams report no open-seat count")
    func uncappedTeam() throws {
        let json = detailJSON.replacingOccurrences(of: "\"memberLimit\": 3", with: "\"memberLimit\": null")
        let detail = try TeamsClient.decoder.decode(CloudTeamDetail.self, from: Data(json.utf8))
        #expect(detail.openSeats == nil)
    }

    @Test("maps the team API error envelope to a coded error")
    func mapsErrorEnvelope() {
        let body = Data(#"{"error":{"code":"seat_limit","message":"This plan includes 3 members."}}"#.utf8)
        let error = TeamsClientError.from(status: 409, body: body)
        #expect(error == .api(code: "seat_limit", status: 409, message: "This plan includes 3 members."))
        #expect(error.apiCode == "seat_limit")
        let plain = TeamsClientError.from(status: 502, body: Data("Bad gateway".utf8))
        #expect(plain == .api(code: "http_502", status: 502, message: "Bad gateway"))
    }

    @Test("path segments refuse empty ids and slashes")
    func pathSegments() throws {
        #expect(try TeamsClient.pathSegment(" abc ") == "abc")
        #expect(throws: TeamsClientError.invalidIdentifier) { try TeamsClient.pathSegment("  ") }
        #expect(throws: TeamsClientError.invalidIdentifier) { try TeamsClient.pathSegment("a/b") }
    }
}
