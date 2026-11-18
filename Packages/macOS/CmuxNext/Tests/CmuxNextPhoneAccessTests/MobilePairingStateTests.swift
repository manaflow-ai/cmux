import CmuxNextMobile
@testable import CmuxNextPhoneAccess
import Testing

/// The page's state names, as webviews/src/pages/mobile-pairing/types.ts reads them.
struct MobilePairingStateTests {
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
