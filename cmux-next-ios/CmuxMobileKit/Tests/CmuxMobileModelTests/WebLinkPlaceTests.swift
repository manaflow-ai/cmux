import Foundation
import Testing
@testable import CmuxMobileModel

/// Leo, 2026-11-14: a github.com link tapped in the terminal on the phone opened on the Mac;
/// only a dev server the Mac hosts should.
@Suite struct WebLinkPlaceTests {
    @Test func publicPagesOpenOnThePhone() {
        for link in ["https://github.com/manaflow-ai/cmux/pull/1", "https://github.com", "http://example.com:8080/x",
                     "https://docs.swift.org/", "https://8.8.8.8/", "https://[2606:4700::1111]/", "https://172.32.0.1/",
                     "https://100.128.0.1/", "https://localhost.example.com/", "https://GitHub.com./login"] {
            #expect(WebLinkPlace(URL(string: link)!) == .phone, "\(link)")
        }
    }

    @Test func pagesOnlyTheMacReachesOpenOnTheMac() {
        for link in ["http://localhost:3000/", "http://LOCALHOST:5173", "http://127.0.0.1:8000/api", "http://[::1]:3000/",
                     "http://0.0.0.0:3000", "http://192.168.1.20:8080", "http://10.0.0.5/", "http://172.16.4.2/",
                     "http://169.254.1.1/", "http://100.101.102.103:3000", "http://app.localhost:3000",
                     "http://my-mac.local:3000", "http://devbox:8080", "https://box.tail1234.ts.net/",
                     "http://[fd7a:115c:a1e0::1]:3000/", "http://[fe80::1]/", "http://router.home.arpa/",
                     "http://svc.internal/", "http://[::ffff:127.0.0.1]:3000/"] {
            #expect(WebLinkPlace(URL(string: link)!) == .mac, "\(link)")
        }
    }
}
