@testable import CmuxNextAgentPane
import Foundation
import Observation
import Testing

/// The app's side of signing in enrolls this Mac only passes each change of the signed-in person to
/// acpmux, which decides the rest (`server/sign_in_follow.rs` and its tests).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudSignInEnrollCallerTests {
    @MainActor final class FakeAcpmux {
        var up = true
        /// The sends refused before acpmux takes one (a line not yet the person's, acpmux not up yet).
        var refuseFirst = 0
        var sent: [[String: String]] = []
        var recorded: [String] = []
        var signedOutAt: [Int64] = []
    }

    /// The app's sign-in as ``CloudSignInEnroll/signedInPerson`` reads it.
    @MainActor @Observable final class FakeAuth {
        var completingSignIn = false
        var userID: String?
        /// The token is readable only once the sign-in finished (`currentTokens()`).
        var token: String? { completingSignIn || userID == nil ? nil : "access" }
    }

    private func caller(_ acpmux: FakeAcpmux, auth: FakeAuth? = nil, retryDelays: [Duration] = [],
                        token: (@MainActor () -> String?)? = nil) -> CloudSignInEnroll {
        CloudSignInEnroll(person: { [weak auth] in
            guard let auth else { return .none }
            return CloudSignInEnroll.signedInPerson(restoring: false, completingSignIn: auth.completingSignIn,
                                                    signedIn: auth.userID != nil, userID: auth.userID)
        }, accessToken: { token?() ?? auth.map { $0.token } ?? "access" }, hub: "https://hub.example", buildTag: nil,
        recordLeave: { userId, at in
            acpmux.recorded.append(userId)
            acpmux.signedOutAt.append(at)
            return true
        }, retryDelays: retryDelays) { params in
            acpmux.sent.append(params.compactMapValues { $0 as? String })
            if acpmux.refuseFirst > 0 {
                acpmux.refuseFirst -= 1
                return false
            }
            return acpmux.up
        }
    }

    @Test func eachChangeGoesToAcpmuxWithTheOneBefore() async {
        let acpmux = FakeAcpmux()
        let enroll = caller(acpmux)
        enroll.changed(to: "user_a")
        enroll.changed(to: "user_a")
        enroll.changed(to: nil)
        await enroll.settled()
        #expect(acpmux.sent == [
            ["userId": "user_a", "accessToken": "access", "hub": "https://hub.example"],
            ["previous": "user_a", "hub": "https://hub.example"],
        ])
        while acpmux.recorded.isEmpty { await Task.yield() }
        #expect(acpmux.recorded == ["user_a"])
        // When the sign-out happened, so acpmux can drop the intent if it lands after a newer sign-in.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        #expect(acpmux.signedOutAt.count == 1 && acpmux.signedOutAt[0] <= now && acpmux.signedOutAt[0] > now - 60000)
    }

    /// #38319 review F1: signing in publishes the person while its team refresh holds the token back.
    /// Nothing is reported until that sign-in finishes; then the person goes with the token.
    @Test func aSignInStillFinishingIsReportedWithItsTokenOnceItEnds() async {
        let acpmux = FakeAcpmux()
        let auth = FakeAuth()
        let enroll = caller(acpmux, auth: auth)
        enroll.follow()
        auth.completingSignIn = true
        auth.userID = "user_a"
        for _ in 0..<50 { await Task.yield() }
        await enroll.settled()
        #expect(acpmux.sent.allSatisfy { $0["userId"] == nil }, "no report while the sign-in finishes")
        auth.completingSignIn = false
        while !acpmux.sent.contains(where: { $0["userId"] == "user_a" }) { await Task.yield() }
        await enroll.settled()
        #expect(acpmux.sent.filter { $0["userId"] == "user_a" } == [
            ["userId": "user_a", "accessToken": "access", "hub": "https://hub.example"],
        ])
    }

    /// #38319 review F3: acpmux took the sign-in, then restarted before its enroll was done. When the
    /// connection comes back, the signed-in person goes again with a token, taken before or not.
    @Test func theSignedInPersonGoesAgainWhenAcpmuxReturns() async {
        let acpmux = FakeAcpmux()
        let enroll = caller(acpmux)
        enroll.changed(to: "user_a")
        await enroll.settled()
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.sent == [
            ["userId": "user_a", "accessToken": "access", "hub": "https://hub.example"],
            ["userId": "user_a", "accessToken": "access", "hub": "https://hub.example"],
        ])
    }

    @Test func aChangeAcpmuxDidNotTakeGoesAgainWhenItReturns() async {
        let acpmux = FakeAcpmux()
        let enroll = caller(acpmux)
        enroll.changed(to: "user_a")
        await enroll.settled()
        acpmux.up = false
        enroll.changed(to: nil)
        await enroll.settled()
        acpmux.up = true
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.sent.count == 3)
        #expect(acpmux.sent.last == ["previous": "user_a", "hub": "https://hub.example"], "the same change, resent")
        // Taken: a later return sends it again too; acpmux changes nothing for it.
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.sent.count == 4)
    }

    /// cloud-carrier-ssh-failover, 2026-11-26: after a sign-out the app opened signed in, but its one
    /// report of that launch went to an acpmux that did not take it (the line not yet the person's), and
    /// nothing sent it again: acpmux never joined. A report not taken goes again until one is.
    @Test func aReportAcpmuxDidNotTakeGoesAgainUntilItIsTaken() async {
        let acpmux = FakeAcpmux()
        acpmux.refuseFirst = 2
        let enroll = caller(acpmux, retryDelays: [.zero, .zero, .zero, .zero])
        enroll.changed(to: "user_a")
        await enroll.settled()
        let report = ["userId": "user_a", "accessToken": "access", "hub": "https://hub.example"]
        #expect(acpmux.sent == [report, report, report], "two refused, the third taken, then no more")
    }

    /// A signed-in report that went with no token (its mint failed) enrolls nothing: it goes again until
    /// one carries the token, which acpmux enrolls with (`sign_in_follow.rs`, the same person with a token).
    @Test func aSignedInReportWithNoTokenGoesAgainWithOne() async {
        let acpmux = FakeAcpmux()
        var mints = 0
        let enroll = caller(acpmux, retryDelays: [.zero, .zero, .zero]) {
            mints += 1
            return mints == 1 ? nil : "access"
        }
        enroll.changed(to: "user_a")
        await enroll.settled()
        #expect(acpmux.sent == [
            ["userId": "user_a", "hub": "https://hub.example"],
            ["userId": "user_a", "accessToken": "access", "hub": "https://hub.example"],
        ])
    }

    /// Tries are bounded: a report acpmux never takes stops after its last wait, until a change or a return.
    @Test func retriesStopAfterTheLastWait() async {
        let acpmux = FakeAcpmux()
        acpmux.up = false
        let enroll = caller(acpmux, retryDelays: [.zero, .zero])
        enroll.changed(to: "user_a")
        await enroll.settled()
        #expect(acpmux.sent.count == 3)
        acpmux.up = true
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.sent.count == 4)
    }

    /// A newer change ends the retry of the one before: a sign-out never brings back the signed-in report.
    @Test func aNewerChangeEndsTheRetryOfTheOneBefore() async {
        let acpmux = FakeAcpmux()
        acpmux.refuseFirst = 1
        let enroll = caller(acpmux, retryDelays: [.seconds(30)])
        enroll.changed(to: "user_a")
        while acpmux.sent.isEmpty { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        enroll.changed(to: nil)
        await enroll.settled()
        #expect(acpmux.sent == [
            ["userId": "user_a", "accessToken": "access", "hub": "https://hub.example"],
            ["previous": "user_a", "hub": "https://hub.example"],
        ])
    }
}
