import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Page authentication challenge")
struct BrowserPageAuthenticationChallengeTests {
    @Test func siteChallengeMapsToAFoundationProtectionSpace() {
        let challenge = BrowserPageAuthenticationChallenge(
            url: URL(string: "https://intranet.example/wiki"), host: "intranet.example", port: 443,
            realm: "Staff", scheme: "Digest", isProxy: false
        )
        let space = challenge.protectionSpace
        #expect(challenge.scheme == "digest")
        #expect(space.host == "intranet.example")
        #expect(space.port == 443)
        #expect(space.protocol == NSURLProtectionSpaceHTTPS)
        #expect(space.realm == "Staff")
        #expect(space.authenticationMethod == NSURLAuthenticationMethodHTTPDigest)
        #expect(!space.isProxy())
    }

    @Test func proxyChallengeIsAProxyProtectionSpace() {
        let challenge = BrowserPageAuthenticationChallenge(
            url: URL(string: "http://a.example/"), host: "proxy.example", port: 3128,
            realm: nil, scheme: "basic", isProxy: true
        )
        let space = challenge.protectionSpace
        #expect(space.isProxy())
        #expect(space.proxyType == NSURLProtectionSpaceHTTPProxy)
        #expect(space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic)
    }

    @Test func unknownSchemeFallsBackToBasic() {
        let challenge = BrowserPageAuthenticationChallenge(
            url: nil, host: "a.example", port: 80, realm: nil, scheme: "weird", isProxy: false
        )
        #expect(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic)
        #expect(challenge.protectionSpace.protocol == NSURLProtectionSpaceHTTP)
    }
}
