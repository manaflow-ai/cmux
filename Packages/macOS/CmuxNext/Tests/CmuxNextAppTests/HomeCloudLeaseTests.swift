import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing

@testable import CmuxNextApp

/// The token lease the app gives the daemon (home-cloud-proxy.md section 2).
@Suite struct HomeCloudLeaseTests {
    @Test func theExpiryIsTheTokensExpClaimInMilliseconds() {
        func jwt(_ payload: String) -> String {
            let body = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(body).sig"
        }
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"sub":"u","exp":1790000000}"#)) == 1_790_000_000_000)
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"sub":"u"}"#)) == nil)
        #expect(HomeCloudLease.expiry(ofJWT: "opaque") == nil)
        #expect(HomeCloudLease.fallbackExpiry(now: Date(timeIntervalSince1970: 1000)) == 1_300_000)
    }

    /// An `exp` out of range is not trusted (and never traps): the lease falls back.
    @Test func anExpOutOfRangeIsIgnored() {
        func jwt(_ payload: String) -> String {
            let body = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(body).sig"
        }
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"exp":1e300}"#)) == nil)
        // Year 2096: far past any token lifetime.
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"exp":4000000000}"#)) == nil)
        let soon = Int(Date().timeIntervalSince1970) + 3600
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"exp":\#(soon)}"#)) == UInt64(soon) * 1000)
    }

    /// The lease is checked against the account the token names.
    @Test func theSubjectIsTheTokensSubClaim() {
        #expect(HomeCloudLease.subject(ofJWT: CloudFixtures.jwt(sub: "u-1")) == "u-1")
        #expect(HomeCloudLease.subject(ofJWT: "opaque") == nil)
        #expect(CloudIdentity.cloudID(stackUserID: "u-1") == CloudIdentity.cloudID(stackUserID: "user_u-1"))
    }

    @Test func theLeaseNamesOnlyTheAPIOrigin() {
        #expect(HomeCloudLease.origin(URL(string: "https://cloud-api.cmux.dev/v1/")!) == "https://cloud-api.cmux.dev")
        #expect(HomeCloudLease.origin(URL(string: "http://127.0.0.1:8787")!) == "http://127.0.0.1:8787")
    }
}
