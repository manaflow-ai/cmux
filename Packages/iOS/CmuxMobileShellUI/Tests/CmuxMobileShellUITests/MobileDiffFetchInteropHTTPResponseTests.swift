import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct MobileDiffFetchInteropHTTPResponseTests {
    private let factory = MobileDiffHTTPResponseFactory()
    private let origin = URL(string: "cmux-mobile-diff://test-host")!

    @Test func patchResponseIsStreamingHTTP() throws {
        let response = try #require(factory.response(
            url: origin.appendingPathComponent("patch"),
            mimeType: "text/x-diff",
            contentLength: nil
        ))

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/x-diff; charset=utf-8")
        #expect(response.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }

    @Test(arguments: [
        ("index.html", "text/html", "text/html; charset=utf-8"),
        ("main.mjs", "text/javascript", "text/javascript; charset=utf-8"),
        ("highlighter.wasm", "application/wasm", "application/wasm"),
    ])
    func assetResponseIsSizedHTTP(
        path: String,
        mimeType: String,
        expectedContentType: String
    ) throws {
        let response = try #require(factory.response(
            url: origin.appendingPathComponent(path),
            mimeType: mimeType,
            contentLength: 42
        ))

        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == expectedContentType)
        #expect(response.value(forHTTPHeaderField: "Content-Length") == "42")
        #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }
}
