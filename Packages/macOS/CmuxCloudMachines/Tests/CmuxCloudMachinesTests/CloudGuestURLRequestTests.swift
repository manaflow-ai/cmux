import Foundation
import Testing
@testable import CmuxCloudMachines

struct CloudGuestURLRequestTests {
    @Test func preservesAuthenticationURLBytes() throws {
        let url = "HTTPS://github.com/login/device?state=AbC%2b%2F#fragment"
        let data = try wire(url)
        #expect(CloudGuestURLRequest(data: data)?.url == url)
    }

    @Test(arguments: ["https://", "file:///tmp/secret", "javascript:alert(1)", "https://foo/a\nb", "https://foo/a b"])
    func rejectsNonWebURLs(_ url: String) throws {
        #expect(CloudGuestURLRequest(data: try wire(url)) == nil)
    }

    @Test func rejectsUnscopedMalformedAndOversizedRequests() throws {
        #expect(CloudGuestURLRequest(data: Data("{}".utf8)) == nil)
        #expect(CloudGuestURLRequest(data: try wire("https://example.com", terminal: "current")) == nil)
        #expect(CloudGuestURLRequest(data: try wire("https://example.com/" + String(repeating: "x", count: 16_384))) == nil)
        #expect(CloudGuestURLRequest(data: try wire("https://example.com", event: "notification")) == nil)
    }

    private func wire(_ url: String, terminal: String = "term_0123456789abcdef0123456789abcdef", event: String = "url-open") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["event": event, "request_id": UUID().uuidString,
                                                   "terminal_id": terminal, "url": url])
    }
}
