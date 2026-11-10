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
}
