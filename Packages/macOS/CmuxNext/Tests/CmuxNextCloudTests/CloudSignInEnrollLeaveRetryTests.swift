@testable import CmuxNextCloud
import Testing

/// A leave or an enroll acpmux did not answer (it was restarting while the app ran) is sent again when
/// the app's acpmux connection comes back, with no relaunch, for whoever is signed in then.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudSignInEnrollLeaveRetryTests {
    /// acpmux as the enroll sees it: down (no reply) or up, with every request it got.
    @MainActor final class FakeAcpmux {
        var up = true
        /// Down for this many more calls, then up again.
        var downFor = 0
        var calls: [String] = []
        /// The account each leave named (nil: none).
        var leaveAccounts: [String?] = []
        /// Whether recording a sign-out's account works (the CLI ran).
        var records = true
        func record(_ userId: String) -> Bool {
            calls.append("record:\(userId)")
            return records
        }
        func call(_ method: String, _ params: [String: Any]) -> [String: Any]? {
            calls.append(method)
            if method == "_acpmux/machine_leave_if_auto" { leaveAccounts.append(params["userId"] as? String) }
            if downFor > 0 {
                downFor -= 1
                return nil
            }
            guard up else { return nil }
            return method == "_acpmux/machine_leave_if_auto" ? ["left": true] : ["outcome": "alreadyJoined"]
        }
        var leaves: Int { calls.filter { $0 == "_acpmux/machine_leave_if_auto" }.count }
        var enrolls: Int { calls.filter { $0 == "_acpmux/machine_enroll" }.count }
    }

    private func enroll(over acpmux: FakeAcpmux) -> CloudSignInEnroll {
        CloudSignInEnroll(person: { .restoring }, accessToken: { "access" }, hub: nil, buildTag: nil,
                          recordLeave: { acpmux.record($0) }) { method, params in
            acpmux.call(method, params)
        }
    }

    @Test func aLeaveWithNoReplyIsSentAgainWhenAcpmuxComesBack() async {
        let acpmux = FakeAcpmux()
        let enroll = enroll(over: acpmux)
        enroll.changed(to: .signedIn("user_me"))
        await enroll.settled()
        // Signed out while acpmux restarts: no reply.
        acpmux.up = false
        enroll.changed(to: .signedOut)
        await enroll.settled()
        #expect(acpmux.leaves == 1)
        #expect(enroll.resendPending)
        // The daemon is back: the one leave goes again and is answered.
        acpmux.up = true
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.leaves == 2)
        #expect(!enroll.resendPending)
        // Answered: a later return sends nothing.
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.leaves == 2)
    }

    @Test func aSignInDropsTheLeaveNotAnswered() async {
        let acpmux = FakeAcpmux()
        let enroll = enroll(over: acpmux)
        enroll.changed(to: .signedIn("user_me"))
        await enroll.settled()
        acpmux.up = false
        enroll.changed(to: .signedOut)
        await enroll.settled()
        #expect(enroll.resendPending)
        acpmux.up = true
        enroll.changed(to: .signedIn("user_me"))
        await enroll.settled()
        #expect(!enroll.resendPending)
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.leaves == 1, "the leave is not sent after the sign-in")
    }

    @Test func anAccountSwitchWhoseLeaveGotNoReplyNeverSendsThatLeaveWhileTheNextPersonIsIn() async {
        let acpmux = FakeAcpmux()
        let enroll = enroll(over: acpmux)
        enroll.changed(to: .signedIn("user_a"))
        await enroll.settled()
        // Switched to B while acpmux restarts: A's leave gets no reply, B's enroll does. acpmux's
        // enroll finishes A's sign-in join's leave itself (`enroll.rs`).
        acpmux.downFor = 1
        enroll.changed(to: .signedIn("user_b"))
        await enroll.settled()
        #expect(acpmux.leaves == 1)
        #expect(acpmux.enrolls == 2)
        #expect(!enroll.resendPending)
        // A later return sends nothing: a leave now would leave B's own join.
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.leaves == 1)
        #expect(acpmux.enrolls == 2)
    }

    @Test func eachLeaveNamesTheAccountSigningOutAndOnlyThatOne() async {
        let acpmux = FakeAcpmux()
        let enroll = enroll(over: acpmux)
        // Signed out at launch: no account is known, so the leave names none.
        enroll.changed(to: .signedOut)
        await enroll.settled()
        enroll.changed(to: .signedIn("user_a"))
        await enroll.settled()
        // A's sign-out goes unanswered, then is sent again, still as A's.
        acpmux.up = false
        enroll.changed(to: .signedOut)
        await enroll.settled()
        acpmux.up = true
        enroll.acpmuxReturned()
        await enroll.settled()
        // A switch to B leaves as A; B's sign-out leaves as B.
        enroll.changed(to: .signedIn("user_a"))
        await enroll.settled()
        enroll.changed(to: .signedIn("user_b"))
        await enroll.settled()
        enroll.changed(to: .signedOut)
        await enroll.settled()
        #expect(acpmux.leaveAccounts == [nil, "user_a", "user_a", "user_a", "user_b"])
    }

    @Test func theSigningOutAccountIsRecordedBeforeTheLeaveAndResentFromIt() async {
        let acpmux = FakeAcpmux()
        let enroll = enroll(over: acpmux)
        enroll.changed(to: .signedIn("user_a"))
        await enroll.settled()
        // acpmux is down: the account is still recorded (the CLI needs no daemon), before the leave.
        acpmux.up = false
        enroll.changed(to: .signedOut)
        await enroll.settled()
        #expect(acpmux.calls.suffix(2) == ["record:user_a", "_acpmux/machine_leave_if_auto"])
        // Back: the leave is resent as A's, recorded again first.
        acpmux.up = true
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.calls.suffix(2) == ["record:user_a", "_acpmux/machine_leave_if_auto"])
        #expect(acpmux.leaveAccounts == ["user_a", "user_a"])
        // Signed out at launch, no account known: nothing is recorded, and acpmux leaves as recorded.
        let relaunched = FakeAcpmux()
        let next = self.enroll(over: relaunched)
        next.changed(to: .signedOut)
        await next.settled()
        #expect(relaunched.calls == ["_acpmux/machine_leave_if_auto"])
        #expect(relaunched.leaveAccounts == [nil])
    }

    @Test func aReturnWithNoLeavePendingSendsNothing() async {
        let acpmux = FakeAcpmux()
        let enroll = enroll(over: acpmux)
        enroll.changed(to: .signedIn("user_me"))
        await enroll.settled()
        enroll.changed(to: .signedOut)
        await enroll.settled()
        #expect(acpmux.leaves == 1)
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.leaves == 1)
    }
}
