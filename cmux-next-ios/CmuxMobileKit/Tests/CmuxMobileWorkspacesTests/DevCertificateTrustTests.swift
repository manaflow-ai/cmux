#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// RFD 0089: an https dev server on the Mac's `localhost` with its own certificate opens on
/// the phone over the forward; every other host keeps iOS's certificate check.
@MainActor @Suite struct DevCertificateTrustTests {
    func trusts(_ host: String, _ port: Int, forwarded: Bool = true) -> Bool {
        MacAddressGuard.trustsDevCertificate(host: host, port: port, isForwarded: { _ in forwarded })
    }

    @Test func forwardedLoopbackIsTrusted() {
        #expect(trusts("localhost", 5173))
        #expect(trusts("127.0.0.1", 8443))
        #expect(trusts("::1", 3000))
        #expect(trusts("LOCALHOST", 443))
    }

    @Test func unforwardedPortKeepsTheCheck() {
        #expect(!trusts("localhost", 5173, forwarded: false))
    }

    @Test func otherHostsKeepTheCheck() {
        for host in ["example.com", "mac.local", "10.0.0.2", "devbox.tail1234.ts.net", "app.localhost", "127.0.0.2", "0.0.0.0"] {
            #expect(!trusts(host, 443), "\(host)")
        }
        #expect(!trusts("localhost", 0))
    }

    @Test func asksAboutThePagesPort() {
        var asked: URL?
        _ = MacAddressGuard.trustsDevCertificate(host: "localhost", port: 5173, isForwarded: { asked = $0; return true })
        #expect(asked.flatMap(PhoneReach.port) == 5173)
    }
}
#endif
