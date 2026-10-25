import Foundation
@testable import CmuxNextMobileHost
import Testing

/// Each paired phone's own acpmux credential (its Full-access setting, off by default), as the
/// approver sync keeps it: revocations hold until acpmux confirms them, and acpmux's phone
/// records no listed phone owns are revoked once per connection.
struct MobileHostPhoneCredentialsTests {
    private static func issued(_ record: String) -> [String: Any] {
        ["result": ["deviceId": record, "token": "tok-" + record]]
    }

    private static func listing(_ devices: [[String: Any]]) -> [String: Any] {
        ["result": ["devices": devices]]
    }

    private static func device(_ id: String, name: String, role: String = "phone", revoked: Bool = false) -> [String: Any] {
        ["id": id, "name": name, "role": role, "revoked_at": revoked ? "2026-10-25T00:00:00Z" : NSNull()]
    }

    /// A phone removed while the app was not running (no longer listed) keeps no record: the first
    /// connection lists acpmux's phone records, even with nothing else to sync, and revokes it.
    @Test func aPhoneRecordNoListedPhoneOwnsIsRevokedOnTheFirstConnection() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        #expect(credentials.setPhones([], ids: &ids).isEmpty)
        #expect(credentials.needsConnection, "the first list is owed with nothing else to sync")
        #expect(credentials.setPhones(["P1"], ids: &ids).isEmpty, "nothing goes before the connection")
        let opened = credentials.connected(ids: &ids)
        #expect(opened.map(\.kind) == [.list, .issue(phone: "P1")])
        let list = try #require(opened.first)
        let revokes = try #require(credentials.reply(id: list.id, Self.listing([
            Self.device("dv_gone", name: "phone-gone"),
            Self.device("dv_old", name: "phone-old", revoked: true),
            Self.device("dv_p1_old", name: "phone-p1"),
            Self.device("dv_mac", name: "phone-mac", role: "client"),
        ]), ids: &ids))
        #expect(revokes.map(\.kind) == [.revoke(record: "dv_gone")], "only a live phone record no listed phone owns")
        #expect(revokes.first?.params["id"] as? String == "dv_gone")
        #expect(credentials.reply(id: try #require(revokes.first).id, ["result": ["revoked": true]], ids: &ids) == [])
        #expect(credentials.reply(id: opened[1].id, Self.issued("dv_p1"), ids: &ids) == [])
        #expect(credentials.tokens == ["P1": "tok-dv_p1"])
        #expect(credentials.pendingRevokes.isEmpty)
        #expect(credentials.setPhones([], ids: &ids).map(\.kind) == [.revoke(record: "dv_p1")])
        #expect(credentials.tokens.isEmpty, "hostd drops it at once")
    }

    /// A revocation whose connection ended before acpmux answered goes again on the next
    /// connection, and the sync keeps asking for one until acpmux confirms it.
    @Test func aRevocationLostWithTheConnectionGoesAgainUntilConfirmed() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        let list = try #require(credentials.connected(ids: &ids).first)
        #expect(credentials.reply(id: list.id, Self.listing([]), ids: &ids) == [])
        #expect(!credentials.needsConnection)
        let issue = try #require(credentials.setPhones(["P1"], ids: &ids).first)
        #expect(credentials.reply(id: issue.id, Self.issued("dv_p1"), ids: &ids) == [])
        let revoke = try #require(credentials.setPhones([], ids: &ids).first)
        #expect(revoke.kind == .revoke(record: "dv_p1"))

        credentials.disconnected()
        #expect(credentials.reply(id: revoke.id, ["result": [String: Any]()], ids: &ids) == nil, "a reply on a lost connection is not one")
        #expect(credentials.pendingRevokes == ["dv_p1"])
        #expect(credentials.needsConnection, "a pending revocation asks for a connection")

        var again = credentials.connected(ids: &ids)
        #expect(again.map(\.kind) == [.list, .revoke(record: "dv_p1")])
        // A refusal other than "already gone" goes again on the next connection.
        #expect(credentials.reply(id: again[1].id, ["error": ["message": "busy"]], ids: &ids) == [])
        #expect(credentials.pendingRevokes == ["dv_p1"])
        credentials.disconnected()
        again = credentials.connected(ids: &ids)
        #expect(again.map(\.kind) == [.list, .revoke(record: "dv_p1")])
        let gone: [String: Any] = ["error": ["message": "no ticket", "data": ["reason": "not_found"]]]
        #expect(credentials.reply(id: again[1].id, gone, ids: &ids) == [])
        #expect(credentials.reply(id: again[0].id, Self.listing([]), ids: &ids) == [])
        #expect(credentials.pendingRevokes.isEmpty)
        #expect(!credentials.needsConnection)
    }

    /// A phone removed while its credential was being issued never gets it: the new record is revoked.
    @Test func aCredentialIssuedForAPhoneRemovedMeanwhileIsRevoked() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        _ = credentials.connected(ids: &ids)
        let issue = try #require(credentials.setPhones(["P1"], ids: &ids).first)
        #expect(credentials.setPhones([], ids: &ids).isEmpty)
        #expect(credentials.reply(id: issue.id, Self.issued("dv_p1"), ids: &ids)?.map(\.kind) == [.revoke(record: "dv_p1")])
        #expect(credentials.tokens.isEmpty)
        #expect(issue.params["role"] as? String == "phone" && issue.params["name"] as? String == "phone-p1")
    }
}
