import Foundation
import Testing
@testable import CmuxAuthRuntime

/// A first sign-in failed validation as `USER_NOT_SIGNED_IN` (#20234 (b)): the SDK says the
/// same for an anonymous user, a restricted one and a rejected token. The failure line names
/// which account the handed-back token was minted for, read from the token itself.
@Suite struct HostBrowserSignInFlowAccessTokenClaimsTests {
    static func jwt(_ claims: [String: Any]) -> String {
        func part(_ object: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(part(["alg": "ES256"])).\(part(claims)).signature"
    }

    @Test func namesAnAnonymousRestrictedExpiredToken() {
        let now = Date(timeIntervalSince1970: 2_000)
        let token = Self.jwt(["sub": "u1", "is_anonymous": true, "is_restricted": true, "exp": 1_000])

        let summary = HostBrowserSignInFlow.accessTokenClaimsSummary(token, now: now)

        #expect(summary == "is_anonymous=true is_restricted=true expired=true")
        #expect(!AuthDebugLog.redacted(summary).contains("<redacted>"))
    }

    @Test func namesAFullAccountsToken() {
        let now = Date(timeIntervalSince1970: 2_000)
        let token = Self.jwt(["sub": "u1", "is_anonymous": false, "is_restricted": false, "exp": 3_000])

        #expect(HostBrowserSignInFlow.accessTokenClaimsSummary(token, now: now)
            == "is_anonymous=false is_restricted=false expired=false")
    }

    @Test func saysWhichClaimsATokenLacks() {
        let token = Self.jwt(["sub": "u1"])

        #expect(HostBrowserSignInFlow.accessTokenClaimsSummary(token, now: Date())
            == "is_anonymous=absent is_restricted=absent expired=absent")
    }

    @Test func saysWhenATokenIsUnreadable() {
        #expect(HostBrowserSignInFlow.accessTokenClaimsSummary("not-a-jwt", now: Date()) == "claims=unreadable")
    }
}
