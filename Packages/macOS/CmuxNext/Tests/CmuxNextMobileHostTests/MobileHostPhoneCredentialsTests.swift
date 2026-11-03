import Foundation
@testable import CmuxNextMobileHost
import Testing

/// Each paired phone's own acpmux credential (its Full-access setting, off by default), as the
/// approver sync keeps it: only a phone the account lists gets one, a removed phone's record ends
/// before it gets a new one, and every revocation holds until a list shows it done.
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

    private static let revoked: [String: Any] = ["result": ["revoked": true]]

    /// At launch the account's list is not read yet: no phone gets a credential and no record is
    /// revoked for being unlisted, so a saved setting survives. Once it is read, an unlisted
    /// record goes and a listed phone gets its credential, after the list.
    @Test func beforeTheAccountsListNothingIsIssuedOrRevokedForBeingUnlisted() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        #expect(credentials.update(paired: ["P1"], listed: nil, ids: &ids).isEmpty)
        let records = [Self.device("dv_p1", name: "phone-p1"), Self.device("dv_gone", name: "phone-gone"),
                       Self.device("dv_old", name: "phone-old", revoked: true), Self.device("dv_mac", name: "phone-mac", role: "client")]
        let first = try #require(credentials.connected(ids: &ids).first)
        #expect(first.kind == .list)
        #expect(credentials.reply(id: first.id, Self.listing(records), ids: &ids) == [], "unread: nothing goes")
        #expect(credentials.tokens.isEmpty)

        let relist = try #require(credentials.update(paired: ["P1"], listed: ["P1"], ids: &ids).first)
        #expect(relist.kind == .list, "the account's list read: the records are listed again")
        let next = try #require(credentials.reply(id: relist.id, Self.listing(records), ids: &ids))
        #expect(next.map(\.kind) == [.revoke(record: "dv_gone"), .issue(phone: "P1")],
                "only a live phone record no listed phone owns; the listed phone's record stays")
        #expect(next[1].params["name"] as? String == "phone-p1" && next[1].params["role"] as? String == "phone")
        let confirm = try #require(credentials.reply(id: next[0].id, Self.revoked, ids: &ids)?.first)
        #expect(confirm.kind == .list, "a list confirms the unlisted record is gone")
        #expect(credentials.reply(id: next[1].id, Self.issued("dv_p1b"), ids: &ids) == [])
        #expect(credentials.reply(id: confirm.id, Self.listing([Self.device("dv_p1b", name: "phone-p1")]), ids: &ids) == [])
        #expect(credentials.tokens == ["P1": "tok-dv_p1b"])
        #expect(credentials.ending.isEmpty)
        #expect(!credentials.refused)
    }

    /// A phone removed, then paired again before acpmux heard the revocation: its old record (and
    /// its setting) ends before the new credential is issued, so the new one starts off.
    @Test func aPhonePairedAgainGetsANewCredentialOnlyAfterItsOldRecordEnds() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        var connection = try Self.connected(&credentials, &ids, listed: ["P1"])
        let issue = try #require(connection.first)
        #expect(credentials.reply(id: issue.id, Self.issued("dv_p1"), ids: &ids) == [])
        #expect(credentials.update(paired: [], listed: [], ids: &ids).map(\.kind) == [.revoke(record: "dv_p1")])
        #expect(credentials.tokens.isEmpty, "hostd drops it at once")
        credentials.disconnected()
        #expect(credentials.update(paired: ["P1"], listed: ["P1"], ids: &ids).isEmpty, "paired again, offline")
        #expect(credentials.needsConnection)

        let list = try #require(credentials.connected(ids: &ids).first)
        connection = try #require(credentials.reply(id: list.id, Self.listing([Self.device("dv_p1", name: "phone-p1")]), ids: &ids))
        #expect(connection.map(\.kind) == [.revoke(record: "dv_p1")], "no issue before the old record ends")
        let relist = try #require(credentials.reply(id: connection[0].id, Self.revoked, ids: &ids)?.first)
        #expect(relist.kind == .list, "a list confirms the record is gone")
        let issueAgain = try #require(credentials.reply(id: relist.id, Self.listing([]), ids: &ids))
        #expect(issueAgain.map(\.kind) == [.issue(phone: "P1")])
        #expect(credentials.ending.isEmpty)
    }

    /// A phone removed while its credential was being issued, and the connection lost before the
    /// reply: the next connection finds the record by its name and revokes it, and the sync keeps
    /// asking for a connection until then.
    @Test func anIssueWhoseReplyWasLostIsFoundAndRevokedByTheNextList() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        _ = try Self.connected(&credentials, &ids, listed: ["P1"])
        #expect(credentials.update(paired: [], listed: [], ids: &ids).isEmpty, "no record id known yet")
        credentials.disconnected()
        #expect(credentials.needsConnection, "a removed phone's record may still be live")

        let list = try #require(credentials.connected(ids: &ids).first)
        let revoke = try #require(credentials.reply(id: list.id, Self.listing([Self.device("dv_new", name: "phone-p1")]), ids: &ids))
        #expect(revoke.map(\.kind) == [.revoke(record: "dv_new")])
        let relist = try #require(credentials.reply(id: revoke[0].id, Self.revoked, ids: &ids)?.first)
        #expect(credentials.reply(id: relist.id, Self.listing([]), ids: &ids) == [])
        #expect(credentials.ending.isEmpty)
        #expect(!credentials.needsConnection)
    }

    /// iPhone connections turned off (the phone still paired, none listed) end its record. A
    /// refused revocation on a healthy connection is marked for a retry on a new connection (the
    /// sync reconnects after its backoff); "already gone" counts as done.
    @Test func aRefusedRevocationIsRetriedOnANewConnection() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        let issue = try #require(try Self.connected(&credentials, &ids, listed: ["P1"]).first)
        #expect(credentials.reply(id: issue.id, Self.issued("dv_p1"), ids: &ids) == [])
        let revoke = try #require(credentials.update(paired: ["P1"], listed: [], ids: &ids).first)
        #expect(revoke.kind == .revoke(record: "dv_p1"))
        _ = credentials.reply(id: revoke.id, ["error": ["message": "store write failed"]], ids: &ids)
        #expect(credentials.refused, "the sync drops the connection and retries after its backoff")
        #expect(credentials.needsConnection)

        credentials.disconnected()
        let list = try #require(credentials.connected(ids: &ids).first)
        let again = try #require(credentials.reply(id: list.id, Self.listing([Self.device("dv_p1", name: "phone-p1")]), ids: &ids))
        #expect(again.map(\.kind) == [.revoke(record: "dv_p1")])
        #expect(!credentials.refused, "the list answered")
        let gone: [String: Any] = ["error": ["message": "no ticket", "data": ["reason": "not_found"]]]
        let relist = try #require(credentials.reply(id: again[0].id, gone, ids: &ids)?.first)
        #expect(!credentials.refused)
        #expect(credentials.reply(id: relist.id, Self.listing([]), ids: &ids) == [])
        #expect(!credentials.needsConnection)
    }

    /// Signing out before the account's list was read, on a connection whose first list already
    /// answered: the next list finds the phone's record and ends it.
    @Test func aRemovalWithNothingUnderWayIsFoundByANewList() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        _ = credentials.update(paired: ["P1"], listed: nil, ids: &ids)
        let first = try #require(credentials.connected(ids: &ids).first)
        let live = Self.listing([Self.device("dv_p1", name: "phone-p1")])
        #expect(credentials.reply(id: first.id, live, ids: &ids) == [])
        let list = try #require(credentials.update(paired: [], listed: nil, ids: &ids).first)
        #expect(list.kind == .list)
        let revoke = try #require(credentials.reply(id: list.id, live, ids: &ids))
        #expect(revoke.map(\.kind) == [.revoke(record: "dv_p1")])
        let relist = try #require(credentials.reply(id: revoke[0].id, Self.revoked, ids: &ids)?.first)
        #expect(credentials.reply(id: relist.id, Self.listing([]), ids: &ids) == [])
        #expect(credentials.ending.isEmpty)
    }

    /// An unlisted record being revoked when its phone shows up in the account's list again: the
    /// phone gets a credential only once a list shows the old record gone, so it starts off.
    @Test func aPhoneListedAgainWaitsForItsUnlistedRecordToEnd() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        _ = credentials.update(paired: ["P1"], listed: [], ids: &ids)
        let first = try #require(credentials.connected(ids: &ids).first)
        let revoke = try #require(credentials.reply(id: first.id, Self.listing([Self.device("dv_old", name: "phone-p1")]), ids: &ids))
        #expect(revoke.map(\.kind) == [.revoke(record: "dv_old")], "unlisted: its record ends")
        #expect(credentials.update(paired: ["P1"], listed: ["P1"], ids: &ids).isEmpty, "no issue while it ends")
        let relist = try #require(credentials.reply(id: revoke[0].id, Self.revoked, ids: &ids)?.first)
        #expect(relist.kind == .list)
        #expect(credentials.reply(id: relist.id, Self.listing([]), ids: &ids)?.map(\.kind) == [.issue(phone: "P1")])
    }

    /// A phone removed while its credential was being issued never gets it: the new record is revoked.
    @Test func aCredentialIssuedForAPhoneRemovedMeanwhileIsRevoked() throws {
        var credentials = MobileHostPhoneCredentials()
        var ids = 10
        let issue = try #require(try Self.connected(&credentials, &ids, listed: ["P1"]).first)
        #expect(credentials.update(paired: [], listed: [], ids: &ids).isEmpty)
        #expect(credentials.reply(id: issue.id, Self.issued("dv_p1"), ids: &ids)?.map(\.kind) == [.revoke(record: "dv_p1")])
        #expect(credentials.tokens.isEmpty)
        #expect(credentials.reply(id: issue.id, Self.issued("dv_p1"), ids: &ids) == nil, "one reply per request")
    }

    /// Connects with `listed` paired and listed, answers the first list with no records, and
    /// returns what goes next (the issues).
    private static func connected(_ credentials: inout MobileHostPhoneCredentials, _ ids: inout Int,
                                  listed: Set<String>) throws -> [MobileHostPhoneCredentials.Request] {
        _ = credentials.update(paired: listed, listed: listed, ids: &ids)
        let list = try #require(credentials.connected(ids: &ids).first)
        return try #require(credentials.reply(id: list.id, listing([]), ids: &ids))
    }
}
