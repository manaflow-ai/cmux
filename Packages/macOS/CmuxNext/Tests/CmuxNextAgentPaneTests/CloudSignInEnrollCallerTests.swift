@testable import CmuxNextAgentPane
import Testing

/// The app's side of signing in enrolls this Mac only passes each change of the signed-in person to
/// acpmux, which decides the rest (`server/sign_in_follow.rs` and its tests).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudSignInEnrollCallerTests {
    @MainActor final class FakeAcpmux {
        var up = true
        var sent: [[String: String]] = []
        var recorded: [String] = []
    }

    private func caller(_ acpmux: FakeAcpmux) -> CloudSignInEnroll {
        CloudSignInEnroll(person: { .none }, accessToken: { "access" }, hub: "https://hub.example", buildTag: nil,
                          recordLeave: { acpmux.recorded.append($0); return true }) { params in
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
        // Taken: a later return sends nothing.
        enroll.acpmuxReturned()
        await enroll.settled()
        #expect(acpmux.sent.count == 3)
    }
}
