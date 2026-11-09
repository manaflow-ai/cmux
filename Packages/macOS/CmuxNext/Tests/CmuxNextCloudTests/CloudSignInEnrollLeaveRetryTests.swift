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
        func call(_ method: String, _: [String: Any]) -> [String: Any]? {
            calls.append(method)
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
        CloudSignInEnroll(person: { .restoring }, accessToken: { "access" }, hub: nil, buildTag: nil) { method, params in
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
