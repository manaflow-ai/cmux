import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// `mobile.autoApprovePhones` (Settings > Accounts > iPhone, off by default): with it on, a phone of
/// the signed-in user pairs as the person's Allow would; with it off, or for a machine or another
/// account, the request waits for the prompt as before (Aziz, 2026-11-20, cmux#13742).
@Suite struct IPhoneAutoApprovePhonesTests {
    static let user = "user-1"

    static func request(kind: String = "phone") -> MobileHostPairRequest {
        MobileHostPairRequest(phoneDeviceID: "phone-1", name: "iPhone", identityKey: "04" + String(repeating: "aa", count: 64),
                              approvalKey: "04" + String(repeating: "bb", count: 64), kind: kind)
    }

    static func approves(_ request: MobileHostPairRequest, on: Bool = true, paired: String = user, account: String? = user) -> Bool {
        IPhoneHostService.autoApproves(request, on: on, pairedUserID: paired, accountUserID: account)
    }

    @Test func onAPhoneOfTheSignedInUserPairsWithoutThePrompt() {
        #expect(Self.approves(Self.request()))
    }

    @Test func offEveryPhoneAsks() {
        #expect(!Self.approves(Self.request(), on: false))
    }

    @Test func anotherAccountOrNoAccountAsks() {
        #expect(!Self.approves(Self.request(), account: "user-2"))
        #expect(!Self.approves(Self.request(), paired: "user-2"))
        #expect(!Self.approves(Self.request(), account: nil))
        #expect(!Self.approves(Self.request(), paired: "", account: ""))
    }

    @Test func aMachineStillAsks() {
        #expect(!Self.approves(Self.request(kind: "mac")))
        #expect(!Self.approves(Self.request(kind: "linux")))
    }
}
