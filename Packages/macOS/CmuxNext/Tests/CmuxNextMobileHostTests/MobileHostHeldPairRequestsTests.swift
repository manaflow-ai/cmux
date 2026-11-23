import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// A pair request that came while the paired list was still loading (the seal read waits for the
/// Keychain) is answered once the list is in, its pairing code with it, instead of being dropped and
/// left to hostd's 120 s prompt timeout (2026-11-18, review.sh on a real iPhone).
@Suite struct MobileHostHeldPairRequestsTests {
    static func request(phone: String, token: String?) -> MobileHostPairRequest {
        MobileHostPairRequest(phoneDeviceID: phone, name: "iPhone", identityKey: "04" + String(repeating: "aa", count: 64),
                              approvalKey: "04" + String(repeating: "bb", count: 64), pairToken: token)
    }

    @Test func aHeldRequestKeepsItsCodeAndIsAnsweredOnce() {
        var held = MobileHostHeldPairRequests()
        held.hold(Self.request(phone: "phone-1", token: "code"))
        let first = held.release()
        #expect(first.map(\.phoneDeviceID) == ["phone-1"])
        #expect(first.first?.pairToken == "code", "the code must still be there to redeem once the list is in")
        let second = held.release()
        #expect(second.isEmpty)
        #expect(held.isEmpty)
    }

    @Test func eachPhoneKeepsItsLatestRequestInArrivalOrder() {
        var held = MobileHostHeldPairRequests()
        held.hold(Self.request(phone: "phone-1", token: nil))
        held.hold(Self.request(phone: "phone-2", token: "b"))
        held.hold(Self.request(phone: "phone-1", token: "a"))
        let released = held.release()
        #expect(released.map(\.phoneDeviceID) == ["phone-1", "phone-2"])
        #expect(released.map(\.pairToken) == ["a", "b"])
    }

    /// The wiring: a request with no list yet is held, not dropped, and the list's arrival answers it.
    @Test func theHostHoldsARequestUntilTheListIsIn() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/CmuxNextMobileHost/IPhoneHostService+Pairing.swift"), encoding: .utf8)
        #expect(source.contains("guard let list = pairedStore.current else {\n            heldPairRequests.hold(request)"))
        #expect(!source.contains("guard allowed, let list = pairedStore.current else { return }"))
        let host = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/CmuxNextMobileHost/IPhoneHostService.swift"), encoding: .utf8)
        #expect(host.contains("pushPaired()\n                answerHeldPairRequests()"))
    }
}
