import Foundation
import Testing
@testable import CmuxIrxTransport

struct MobileIrxControlLaneClaimsTests {
    @Test("allows one owner per session and releases only that owner's sessions")
    func ownershipIsExclusiveAndReleaseIsScoped() {
        var claims = MobileIrxControlLaneClaims()
        let firstOwner = UUID()
        let secondOwner = UUID()

        let firstClaim = claims.claim(sessionID: "alpha", ownerID: firstOwner)
        #expect(firstClaim)
        let conflictingClaim = claims.claim(sessionID: "alpha", ownerID: secondOwner)
        #expect(!conflictingClaim)
        let secondClaim = claims.claim(sessionID: "beta", ownerID: secondOwner)
        #expect(secondClaim)

        claims.release(ownerID: firstOwner)
        let reclaimedSession = claims.claim(sessionID: "alpha", ownerID: secondOwner)
        #expect(reclaimedSession)
        let retainedSession = claims.claim(sessionID: "beta", ownerID: secondOwner)
        #expect(retainedSession)

        claims.removeAll()
        let postResetClaim = claims.claim(sessionID: "alpha", ownerID: firstOwner)
        #expect(postResetClaim)
    }
}
