import CmuxMobileRPC
import Foundation
import Testing

/// `feed.list` drops a row it can't decode, so a timestamp the decoder
/// rejects makes a valid row vanish from the mobile agent feed.
@Suite("Agent feed list timestamps")
struct MobileAgentFeedListResponseDateTests {
    @Test("A row with fractional-second timestamps decodes")
    func fractionalSecondsDecode() throws {
        let response = try MobileAgentFeedListResponse.decode(Self.feed(
            createdAt: "2026-09-30T22:44:53.481Z",
            updatedAt: "2026-09-30T22:44:54.002Z"
        ))

        let item = try #require(response.items.first)
        #expect(response.items.count == 1)
        #expect(abs(item.createdAt.timeIntervalSince1970 - 1_790_808_293.481) < 0.0005)
        #expect(abs(item.updatedAt.timeIntervalSince1970 - 1_790_808_294.002) < 0.0005)
    }

    @Test("Whole-second and epoch timestamps still decode")
    func existingFormatsStillDecode() throws {
        let iso = try MobileAgentFeedListResponse.decode(Self.feed(
            createdAt: "2026-09-30T22:44:53Z",
            updatedAt: "2026-09-30T22:44:54Z"
        ))
        #expect(iso.items.first?.createdAt == Date(timeIntervalSince1970: 1_790_808_293))

        let epoch = try MobileAgentFeedListResponse.decode(Self.feed(
            createdAt: 1_790_808_293.5,
            updatedAt: 1_790_808_294
        ))
        #expect(epoch.items.first?.createdAt == Date(timeIntervalSince1970: 1_790_808_293.5))
    }

    @Test("A row with an unparseable timestamp is still dropped")
    func malformedTimestampDropsOnlyThatRow() throws {
        let rows: [[String: Any]] = [
            Self.row(id: "bad", createdAt: "yesterday", updatedAt: "yesterday"),
            Self.row(id: "good", createdAt: "2026-09-30T22:44:53.481Z", updatedAt: "2026-09-30T22:44:53.481Z"),
        ]
        let data = try JSONSerialization.data(withJSONObject: ["revision": 1, "items": rows])

        let response = try MobileAgentFeedListResponse.decode(data)

        #expect(response.items.map(\.id) == ["good"])
    }

    private static func feed(createdAt: Any, updatedAt: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "revision": 1,
            "items": [row(id: "item-1", createdAt: createdAt, updatedAt: updatedAt)],
        ])
    }

    private static func row(id: String, createdAt: Any, updatedAt: Any) -> [String: Any] {
        [
            "id": id,
            "workstream_id": "claude-s1",
            "source": "claude",
            "kind": "permission_request",
            "status": "pending",
            "created_at": createdAt,
            "updated_at": updatedAt,
        ]
    }
}
