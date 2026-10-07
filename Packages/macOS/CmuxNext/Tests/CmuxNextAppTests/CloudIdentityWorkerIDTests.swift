import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The Worker names a signed-in user `user_` + the first 20 hex digits of
/// sha256("stack:<project>:<stack user id>") (backend domains/user.ts
/// `userIdFor`), not `user_<stack id>`. Seen on hmdm1 against staging: my
/// own participant showed as "Member", a DM invite listed as a group, and
/// conversation.create was refused (forbidden) because it named me by the
/// wrong id.
@Suite struct CloudIdentityWorkerIDTests {
    static let identity = CloudIdentity(stackUserID: "stack-me", displayName: "Me", localID: ParticipantID("user_local"),
                                        stackProjectID: "proj-1")

    @Test func theParticipantIDIsTheWorkersUserID() {
        #expect(Self.identity.participantID == "user_0eeb694177d9b0ea2010")
        #expect(Self.identity.participant.id == "user_0eeb694177d9b0ea2010")
    }

    @Test func theWorkersIDMapsToTheStoresUserBothWays() {
        #expect(Self.identity.toHome("user_0eeb694177d9b0ea2010") == ParticipantID("user_local"))
        #expect(Self.identity.toCloud(ParticipantID("user_local")) == "user_0eeb694177d9b0ea2010")
        #expect(Self.identity.toHome("user_other") == ParticipantID("user_other"))
    }

    /// The account checks keep the Stack-based id the daemon reports.
    @Test func theAccountIDStaysTheStackID() {
        #expect(Self.identity.cloudID == "user_stack-me")
    }
}
