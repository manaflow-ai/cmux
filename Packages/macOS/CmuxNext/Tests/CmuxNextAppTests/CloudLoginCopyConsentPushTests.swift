@testable import CmuxNextCloudCredentials
import Testing

/// The daemon's login copies read the consent the app last sent (`cloud-spare-warm-consent`). A change made while the
/// daemon link was down must reach the daemon when it comes back, and a reconnect resends it even when unchanged (a
/// restarted daemon holds none).
@Suite struct CloudLoginCopyConsentPushTests {
    @Test func aReconnectResendsTheConsentAndAChangeWhileDownIsNotLost() {
        var push = CloudLoginCopyConsentPush()
        #expect(push.next(.init(live: true, consent: true)) == .some(true), "the first state is sent")
        #expect(push.next(.init(live: true, consent: true)) == nil, "the same value on the same link is not")
        #expect(push.next(.init(live: false, consent: false)) == nil, "nothing is sent while the link is down")
        #expect(push.next(.init(live: true, consent: false)) == .some(false), "the change made while down, on reconnect")
        #expect(push.next(.init(live: false, consent: false)) == nil)
        #expect(push.next(.init(live: true, consent: false)) == .some(false), "a reconnect resends it unchanged")
        #expect(push.next(.init(live: true, consent: nil)) == .some(nil), "taken back (never asked) is sent as null")
    }

    @Test func aFailedSendIsSentAgain() {
        var push = CloudLoginCopyConsentPush()
        #expect(push.next(.init(live: true, consent: true)) == .some(true))
        push.failed()
        #expect(push.next(.init(live: true, consent: true)) == .some(true))
    }

    /// Codex #40268 F1: a failed send with the link still up and the consent unchanged has no next state to ride on;
    /// it is sent again after a pause, so the daemon hears an opt-out before a copy in flight writes.
    @MainActor @Test func aFailedSendIsRetriedWhileTheLinkStaysUp() async {
        var push = CloudLoginCopyConsentPush()
        var sent: [Bool?] = [], pauses: [Duration] = [], answers = [false, false, true], number: UInt64 = 0
        await push.send({ .init(live: true, consent: false) }, numbered: { number += 1; return number }, { value, _ in
            sent.append(value)
            return answers.removeFirst()
        }, pause: { pauses.append($0); return true })
        #expect(sent == [false, false, false], "two failures, then the third try lands")
        #expect(pauses == Array(CloudLoginCopyConsentPush.retryDelays.prefix(2)))
        #expect(push.next(.init(live: true, consent: false)) == nil, "the landed value is not sent again")
    }

    @MainActor @Test func aRetryStopsWhenTheLinkDropsOrTheFollowerEnds() async {
        var push = CloudLoginCopyConsentPush(), live = true, tries = 0
        await push.send({ .init(live: live, consent: false) }, numbered: { 1 }, { _, _ in
            tries += 1
            live = false
            return false
        }, pause: { _ in true })
        #expect(tries == 1, "the link went down: the reconnect resends, not the retry")
        var cancelled = CloudLoginCopyConsentPush(), calls = 0
        await cancelled.send({ .init(live: true, consent: true) }, numbered: { 1 }, { _, _ in calls += 1; return false },
                             pause: { _ in false })
        #expect(calls == 1, "a cancelled follower stops at its pause")
    }

    @MainActor @Test func everyConsentReadIsNumberedAfterTheLastOne() {
        // A warm numbers its read before it awaits its tokens; the follower's later read gets a larger number, so the
        // daemon (`set_consent`) drops the warm's stale send if it arrives last.
        let claims = CloudClaimedCopyRegistrations()
        let warm = claims.consentGeneration(), follower = claims.consentGeneration()
        #expect(follower > warm)
        #expect(claims.consentGeneration() > follower)
    }
}
