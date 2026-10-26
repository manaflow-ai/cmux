import Foundation
import Testing
@testable import CmuxNextMobile

/// ``MobileHostPairing``: the steps `IPhoneHostService` asks for every pairing decision (a phone asks,
/// the person answers, a phone is forgotten), each against the signed-in user's own list only.
@Suite struct MobileHostPairingStepTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let request = MobileHostPairRequest(phoneDeviceID: "p1", name: "iPhone", identityKey: "04" + String(repeating: "aa", count: 64),
                                               approvalKey: "04" + String(repeating: "bb", count: 64))
    static let other = MobileHostPairRequest(phoneDeviceID: "p2", name: "iPad", identityKey: "04" + String(repeating: "cc", count: 64),
                                             approvalKey: "04" + String(repeating: "dd", count: 64))

    static func signedIn() -> MobileHostPairing {
        MobileHostPairing(paired: MobileHostPairedDevices(userID: "user-1"))
    }

    @Test func aRequestAsksNothingWhileConnectionsAreOffOrNoOneIsSignedIn() {
        var off = Self.signedIn()
        let whileOff = off.ask(Self.request, allowed: false, userID: "user-1", at: Self.now) { _ in true }
        #expect(whileOff == .ignored)
        #expect(off == Self.signedIn())
        var signedOut = MobileHostPairing()
        let whileSignedOut = signedOut.ask(Self.request, allowed: true, userID: nil, at: Self.now) { _ in true }
        #expect(whileSignedOut == .ignored)
        #expect(signedOut == MobileHostPairing())
    }

    @Test func theSeedPairsOnlyIntoTheSignedInUsersOwnList() {
        var own = Self.signedIn()
        let seeded = own.ask(Self.request, allowed: true, userID: "user-1", at: Self.now) { _ in true }
        #expect(seeded == .seeded)
        #expect(own.paired?.decision(for: Self.request) == .trusted)
        #expect(own.prompts.pending.isEmpty)
        // The list already trusts the phone: the seed is not read again.
        var seedReads = 0
        let again = own.ask(Self.request, allowed: true, userID: "user-1", at: Self.now) { _ in
            seedReads += 1
            return true
        }
        #expect(again == .known)
        #expect(seedReads == 0)

        var another = Self.signedIn()
        let underAnotherUser = another.ask(Self.request, allowed: true, userID: "user-2", at: Self.now) { _ in true }
        #expect(underAnotherUser == .prompted(.ask))
        #expect(another.paired?.decision(for: Self.request) == .ask)
        #expect(another.prompts.pending == [Self.request])
    }

    @Test func anAnswerIsWrittenOnlyToTheSignedInUsersOwnList() {
        var pairing = Self.signedIn()
        _ = pairing.ask(Self.request, allowed: true, userID: "user-1", at: Self.now) { _ in false }
        _ = pairing.ask(Self.other, allowed: true, userID: "user-1", at: Self.now) { _ in false }
        let allowed = pairing.decide(Self.request, allow: true, userID: "user-1", at: Self.now)
        #expect(allowed)
        #expect(pairing.paired?.decision(for: Self.request) == .trusted)
        #expect(pairing.prompts.pending == [Self.other])

        let deniedElsewhere = pairing.decide(Self.other, allow: false, userID: "user-2", at: Self.now)
        #expect(!deniedElsewhere)
        #expect(pairing.paired?.decision(for: Self.other) == .ask, "an answer under another user changed this list")
        #expect(pairing.prompts.pending.isEmpty)
        #expect(pairing.prompts.isQuiet(at: Self.now))
    }

    @Test func revokingAPhoneForgetsItsPromptAndPairingOnly() {
        var pairing = Self.signedIn()
        _ = pairing.ask(Self.request, allowed: true, userID: "user-1", at: Self.now) { _ in true }
        _ = pairing.ask(Self.other, allowed: true, userID: "user-1", at: Self.now) { _ in false }
        let first = pairing.revoke(id: "p1")
        #expect(first)
        #expect(pairing.paired?.decision(for: Self.request) == .ask)
        #expect(pairing.prompts.pending == [Self.other])
        let second = pairing.revoke(id: "p2")
        #expect(second)
        #expect(pairing.prompts.pending.isEmpty)
        var signedOut = MobileHostPairing()
        let withoutList = signedOut.revoke(id: "p1")
        #expect(!withoutList)
    }
}
