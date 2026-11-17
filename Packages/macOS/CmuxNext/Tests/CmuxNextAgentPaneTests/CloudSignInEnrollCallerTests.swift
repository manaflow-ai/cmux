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

    private func caller(_ acpmux: FakeAcpmux, auth: FakeAuth? = nil) -> CloudSignInEnroll {
        CloudSignInEnroll(person: { [weak auth] in
            guard let auth else { return .none }
            return CloudSignInEnroll.signedInPerson(restoring: false, completingSignIn: auth.completingSignIn,
                                                    signedIn: auth.userID != nil, userID: auth.userID)
        }, accessToken: { auth.map { $0.token } ?? "access" }, hub: "https://hub.example", buildTag: nil,
        recordLeave: { userId, at in
            acpmux.recorded.append(userId)
            acpmux.signedOutAt.append(at)
            return true
        }) { params in
            acpmux.sent.append(params.compactMapValues { $0 as? String })
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
}
