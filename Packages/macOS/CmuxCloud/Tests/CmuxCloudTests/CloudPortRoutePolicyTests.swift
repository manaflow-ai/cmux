import CmuxCloud
import Foundation
import Testing

@Suite("Cloud port route policy")
struct CloudPortRoutePolicyTests {
    private let policy = CloudPortRoutePolicy()

    @Test("preserves URL components while replacing an IPv6 private host")
    func privateURLPreservesComponents() {
        #expect(policy.privateURL(
            "https://localhost:8443/a%20b?q=%2F#frag",
            address: "fd12::7"
        )?.absoluteString == "https://[fd12::7]:8443/a%20b?q=%2F#frag")
    }

    @Test("accepts SSH loopback only when explicitly enabled")
    func loopbackRequiresOptIn() {
        #expect(policy.privateURL("http://localhost:3000", address: "127.0.0.1") == nil)
        #expect(policy.privateURL("http://localhost:3000", address: "::1", allowLoopback: true)?.host == "::1")
    }

    @Test("rewrites only HTTP routes to the local forward")
    func localForwardPolicy() {
        #expect(policy.localURL(
            rewriting: "http://10.0.0.7:3000/path?x=1#frag",
            toLoopbackPort: 41000
        )?.absoluteString == "http://127.0.0.1:41000/path?x=1#frag")
        #expect(policy.localURL(rewriting: "https://10.0.0.7:8443", toLoopbackPort: 41000) == nil)
    }
}
