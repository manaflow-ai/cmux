@testable import CmuxNextCloud
import Testing

/// A refused link ends a wait only while it is the current connect's answer.
@MainActor @Suite
struct CloudLinkRefusalTests {
    @Test func aHelperThatCannotStartIsRefusedUntilTheNextConnect() {
        let refusal = CloudLinkRefusal()
        refusal.connecting()
        refusal.ended(CloudCarrierDial.serveStartError(code: "handshake", detail: "no device key", socket: "/tmp/s.sock"))
        #expect(refusal.refused && refusal.reason == "no device key")
        // A wait that begins while that connect's answer stands (its connect is still the last) ends on it.
        refusal.waitBegins(connecting: true)
        #expect(refusal.refused)
        refusal.connecting()
        #expect(!refusal.refused && refusal.reason == nil)
    }

    @Test func aWaitWithNoConnectInFlightForgetsAnOldRefusal() {
        let refusal = CloudLinkRefusal()
        refusal.ended(CloudCarrierDial.serveStartError(code: "handshake", detail: nil, socket: "/tmp/s.sock"))
        #expect(refusal.refused)
        refusal.waitBegins(connecting: false)
        #expect(!refusal.refused, "a connect a guard skipped never ends a new wait on an old answer")
    }

    @Test func aFailureAnotherConnectCanHelpIsNotARefusal() {
        let refusal = CloudLinkRefusal()
        refusal.ended(CloudCarrierDial.linkError(code: "relay", detail: nil))
        #expect(!refusal.refused)
        refusal.ended(CloudLinkError.helperNotRunning(reason: "cmux carrier serve missed its deadline"))
        #expect(!refusal.refused && refusal.reason == "cmux carrier serve missed its deadline")
    }
}
