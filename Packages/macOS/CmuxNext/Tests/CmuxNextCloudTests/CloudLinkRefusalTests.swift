@testable import CmuxNextCloud
import Testing

/// A refused link ends a wait only while it is the current connect's answer.
@MainActor @Suite
struct CloudLinkRefusalTests {
    @Test func aHelperThatCannotStartIsRefusedUntilTheNextConnect() {
        let refusal = CloudLinkRefusal()
        refusal.connecting()
        refusal.ended(CloudLinkError.helperRefused(code: "handshake", message: "handshake: no device key"))
        #expect(refusal.refused && refusal.reason == "no device key")
        // A wait that begins while that connect's answer stands (its connect is still the last) ends on it.
        refusal.waitBegins(connecting: true)
        #expect(refusal.refused)
        refusal.connecting()
        #expect(!refusal.refused && refusal.reason == nil)
    }

    @Test func aWaitWithNoConnectInFlightForgetsAnOldRefusal() {
        let refusal = CloudLinkRefusal()
        refusal.ended(CloudLinkError.helperRefused(code: "handshake", message: ""))
        #expect(refusal.refused)
        refusal.waitBegins(connecting: false)
        #expect(!refusal.refused, "a connect a guard skipped never ends a new wait on an old answer")
    }

    @Test func aFailureAnotherConnectCanHelpIsNotARefusal() {
        let refusal = CloudLinkRefusal()
        refusal.ended(CloudLinkError.disconnected(reason: "relay"))
        #expect(!refusal.refused)
        refusal.ended(CloudLinkError.helperNotRunning(reason: "cmux carrier serve missed its deadline"))
        #expect(!refusal.refused && refusal.reason == "cmux carrier serve missed its deadline")
    }
}
