import CmuxNextMobile
@testable import CmuxNextPhoneAccess
import Testing

/// The Mobile Pairing page names the one missing step: an account first,
/// then phone access, then a listener that is up. A listener failure shows
/// as itself, and a listener that is between runs reads as preparing.
struct MobilePairingStateTests {
    @Test func signingInComesFirst() {
        #expect(MobilePairingState.resolve(signedIn: false, allowed: true, phase: .listening(relayURL: nil)) == .signedOut)
        #expect(MobilePairingState.resolve(signedIn: false, allowed: false, phase: nil) == .signedOut)
    }

    @Test func phoneAccessOffIsTheNextStep() {
        #expect(MobilePairingState.resolve(signedIn: true, allowed: false, phase: nil) == .accessOff)
        #expect(MobilePairingState.resolve(signedIn: true, allowed: false, phase: .listening(relayURL: "https://r")) == .accessOff)
    }

    @Test(arguments: [nil, MobileIrxHost.Phase.idle, .provisioning, .waitingForRelay, .stopped])
    func aListenerOnItsWayIsPreparing(phase: MobileIrxHost.Phase?) {
        #expect(MobilePairingState.resolve(signedIn: true, allowed: true, phase: phase) == .preparing)
    }

    @Test func aListeningHostIsReady() {
        #expect(MobilePairingState.resolve(signedIn: true, allowed: true, phase: .listening(relayURL: "https://relay")) == .ready)
    }

    @Test func aFailedListenerSaysWhy() {
        #expect(MobilePairingState.resolve(signedIn: true, allowed: true, phase: .failed("relay refused")) == .failed("relay refused"))
    }

    @Test func wireNamesMatchThePage() {
        #expect(MobilePairingState.signedOut.wireName == "signedOut")
        #expect(MobilePairingState.accessOff.wireName == "accessOff")
        #expect(MobilePairingState.preparing.wireName == "preparing")
        #expect(MobilePairingState.ready.wireName == "ready")
        #expect(MobilePairingState.failed("x").wireName == "failed")
    }
}

/// The page's steps for the iPhone host (`IPhoneHostService`): online is ready, starting or
/// retrying is preparing, and a build without hostd or a removed Mac says why.
struct MobilePairingHostStateTests {
    @Test func accountThenSwitchThenHost() {
        #expect(MobilePairingState.resolve(signedIn: false, allowed: true, host: .online, removedReason: "r") == .signedOut)
        #expect(MobilePairingState.resolve(signedIn: true, allowed: false, host: .online, removedReason: "r") == .accessOff)
        #expect(MobilePairingState.resolve(signedIn: true, allowed: true, host: .online, removedReason: "r") == .ready)
    }

    @Test(arguments: [MobileHostState.Phase.off, .connecting, .waiting("network")])
    func aHostOnItsWayIsPreparing(phase: MobileHostState.Phase) {
        #expect(MobilePairingState.resolve(signedIn: true, allowed: true, host: phase, removedReason: "r") == .preparing)
    }

    @Test func aHostThatCannotRunSaysWhy() {
        #expect(MobilePairingState.resolve(signedIn: true, allowed: true, host: .unavailable("no hostd"), removedReason: "r") == .failed("no hostd"))
        #expect(MobilePairingState.resolve(signedIn: true, allowed: true, host: .removed, removedReason: "Removed") == .failed("Removed"))
    }
}
