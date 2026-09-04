import Foundation
import Testing

@testable import CmuxMobileIrxControl

@Suite("IRX control lane claims")
struct MobileIrxControlLaneClaimsTests {
    @Test
    func distinctMacSessionsRemainIndependentlyOwned() {
        var claims = MobileIrxControlLaneClaims()
        let firstOwner = UUID()
        let secondOwner = UUID()

        let firstClaimed = claims.claim(sessionID: "mac-a-session", ownerID: firstOwner)
        let secondClaimed = claims.claim(sessionID: "mac-b-session", ownerID: secondOwner)
        let conflictingClaim = claims.claim(sessionID: "mac-a-session", ownerID: secondOwner)
        #expect(firstClaimed)
        #expect(secondClaimed)
        #expect(!conflictingClaim)

        claims.release(ownerID: firstOwner)

        let reclaimed = claims.claim(sessionID: "mac-a-session", ownerID: secondOwner)
        let retained = claims.claim(sessionID: "mac-b-session", ownerID: secondOwner)
        #expect(reclaimed)
        #expect(retained)
    }
}
