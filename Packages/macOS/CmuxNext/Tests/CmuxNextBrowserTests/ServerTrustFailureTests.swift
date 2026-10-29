@testable import CmuxNextBrowser
import Foundation
import Security
import Testing

/// A failed server trust gives Page Info its chain and reason (the trust is no longer
/// boxed across threads; WebKit's delegate evaluates it with `SecTrustEvaluateAsyncWithError`). Off main, as the probe runs it.
@Suite nonisolated struct ServerTrustFailureTests {
    @Test func aRootUsedAsAServerForAnotherHostFailsWithItsChainAndAReason() throws {
        var anchors: CFArray?
        _ = SecTrustCopyAnchorCertificates(&anchors)
        let anchor = try #require((anchors as? [SecCertificate])?.first)
        var made: SecTrust?
        _ = SecTrustCreateWithCertificates(anchor, SecPolicyCreateSSL(true, "cmux.invalid" as CFString), &made)
        let trust = try #require(made)
        _ = SecTrustSetNetworkFetchAllowed(trust, false)

        let failure = try #require(ServerTrustFailure.evaluate(trust))
        #expect(failure.chain.first == SecCertificateCopyData(anchor) as Data)
        #expect(failure.reason?.isEmpty == false)
    }
}
