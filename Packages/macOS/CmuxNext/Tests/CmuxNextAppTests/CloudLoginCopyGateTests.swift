import CmuxNextCloudCredentials
import Testing

/// The Release copy of the person's Claude login (``CloudLoginCopyGate``, Leo 2026-11-02): the switch
/// first, then the consent, asked once; a DEV or NIGHTLY build reads neither.
@MainActor
struct CloudLoginCopyGateTests {
    final class Calls { var asks = 0, reads = 0 }

    func gate(dogfood: Bool = false, on: Bool?, consent: Bool?, answer: Bool = true, _ calls: Calls = Calls()) -> CloudLoginCopyGate {
        CloudLoginCopyGate(dogfood: dogfood, readSwitch: { calls.reads += 1; return on }, consent: { consent },
                           ask: { calls.asks += 1; return answer })
    }

    @Test func aDogfoodBuildReadsNothing() async {
        let calls = Calls()
        let gate = gate(dogfood: true, on: false, consent: false, calls)
        #expect(await gate.copyAllowed())
        #expect(await gate.stillAllowed())
        #expect(await gate.recoveryAllowed(claude: false, automatic: true))
        var decision = CloudHarnessLoginDecision(dogfood: true, setting: nil, harness: "claude", signedIn: true)
        await gate.read(into: &decision)
        #expect(decision.remoteSwitch == nil && decision.consent == nil)
        #expect(calls.reads == 0 && calls.asks == 0)
    }

    @Test func releaseNeedsTheSwitchThenTheConsentAskedOnce() async {
        #expect(await !gate(on: false, consent: true).copyAllowed(), "the switch off holds the copy")
        #expect(await !gate(on: nil, consent: true).copyAllowed(), "an unread switch is off")
        #expect(await gate(on: true, consent: true).copyAllowed())
        #expect(await !gate(on: true, consent: false).copyAllowed(), "a no is kept, never asked again")
        let calls = Calls()
        #expect(await gate(on: true, consent: nil, answer: true, calls).copyAllowed())
        #expect(calls.asks == 1)
    }

    @Test func anAutomaticRecoveryNeverAsksAndOnlyClaudeIsCopied() async {
        let calls = Calls()
        #expect(await !gate(on: true, consent: nil, calls).recoveryAllowed(claude: true, automatic: true))
        #expect(calls.asks == 0)
        #expect(await !gate(on: true, consent: true).recoveryAllowed(claude: false, automatic: false))
        #expect(await gate(on: true, consent: true).recoveryAllowed(claude: true, automatic: true))
        #expect(await gate(on: true, consent: true).stillAllowed())
        #expect(await !gate(on: false, consent: true).stillAllowed())
    }
}
