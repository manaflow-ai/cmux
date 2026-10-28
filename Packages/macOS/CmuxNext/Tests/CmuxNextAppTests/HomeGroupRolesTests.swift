import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Group roles (owner, admin, member, read_only) and large groups (a roster plus `member_count`)
/// as the group info sheet shows them, from the Cloud head through the Home core.
@MainActor @Suite
struct HomeGroupRolesTests {
    let identity = CloudIdentity(stackUserID: "me", displayName: "Lawrence", localID: ParticipantID("user_me"))

    func head(_ json: String) throws -> CmuxNextDaemon.ConversationSummary {
        try JSONDecoder().decode(CmuxNextDaemon.ConversationSummary.self, from: Data(json.utf8))
    }

    /// The owner's role reaches the Home participant; an unknown role is no role.
    @Test func theOwnersRoleReachesTheMember() throws {
        let wire = try head("""
        {"id":"conv_g","owner":"cloud","title":"Launch","kind":"group","last_seq":1,"rev":1,
         "created_at":"2026-10-01T00:00:00.000Z","updated_at":"2026-10-01T00:00:00.000Z","read_cursors":{},
         "participants":[
          {"id":"user_me","kind":"human","display_name":"Lawrence","role":"owner"},
          {"id":"user_aziz","kind":"human","display_name":"Aziz","role":"admin"},
          {"id":"user_leo","kind":"human","display_name":"Leo","role":"read_only"},
          {"id":"user_sam","kind":"human","display_name":"Sam","role":"member"},
          {"id":"user_kim","kind":"human","display_name":"Kim","role":"emperor"}]}
        """)
        let summary = CloudHomeMapping.summary(wire, identity: identity)
        let roles = summary.participants.map(\.role)
        #expect(roles == [.owner, .admin, .readOnly, .member, nil])
        #expect(summary.memberCount == nil)
    }

    /// A large group's head carries a roster and the full count.
    @Test func aLargeGroupCarriesItsMemberCount() throws {
        let wire = try head("""
        {"id":"conv_big","owner":"cloud","title":"Everyone","kind":"group","last_seq":1,"rev":1,
         "created_at":"2026-10-01T00:00:00.000Z","updated_at":"2026-10-01T00:00:00.000Z","read_cursors":{},
         "member_count":5000,
         "participants":[{"id":"user_me","kind":"human","display_name":"Lawrence","role":"owner"}]}
        """)
        #expect(wire.memberCount == 5000)
        #expect(CloudHomeMapping.summary(wire, identity: identity).memberCount == 5000)
    }

    /// The sheet tags the owner, an admin and a read-only member; a plain member has no tag.
    @Test(arguments: [(Participant.Role.owner, true), (.admin, true), (.member, false), (.readOnly, true)])
    func aMemberShowsItsRole(role: Participant.Role, tagged: Bool) {
        let person = Participant(id: ParticipantID("user_aziz"), kind: .human, displayName: "Aziz", role: role)
        let member = HomeGroupMember(person, me: ParticipantID("user_me"))
        #expect(member.role == role)
        #expect((member.roleTag?.isEmpty == false) == tagged)
    }

    /// The members header counts the whole group when the head says how many there are.
    @Test func theHeaderCountsALargeGroup() {
        let small = HomeGroupInfo(conversation: ConversationID("a"), isGroup: true, title: "", displayTitle: "A", members: [],
                                  canMute: true, muted: false)
        var large = small
        large.memberCount = 5000
        #expect(small.membersHeader == HomeGroupInfo.membersHeader(count: nil))
        #expect(large.membersHeader.contains("5"))
        #expect(large.membersHeader != small.membersHeader)
    }

    /// A read-only member's change is refused with its own words.
    @Test func readOnlyIsSaidSo() {
        let outcome = HomeGroupOutcome(rejection: .invalid("read_only"), naming: "")
        #expect(outcome == .readOnly)
        #expect(outcome.message?.isEmpty == false)
        #expect(outcome.message != HomeGroupOutcome.forbidden.message)
    }
}
