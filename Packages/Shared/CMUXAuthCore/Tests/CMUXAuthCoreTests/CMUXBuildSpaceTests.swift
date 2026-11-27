import CMUXAuthCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite("CMUXBuildSpace")
struct CMUXBuildSpaceTests {
    @Test("A tag is sanitized like scripts/lib/mobile-attach.sh cmux_attach__slug_raw", arguments: [
        ("My_Tag 2", "my-tag-2"),
        ("--a--", "a"),
        ("feat-cnx-build-spaces", "feat-cnx-build-spaces"),
        (".demo", "demo"),
        ("A..B__C", "a-b-c"),
        ("caf\u{E9} 9", "caf-9"),
        ("\u{212A}elvin", "elvin"),
    ])
    func slug(raw: String, expected: String) {
        #expect(CMUXBuildSpace.slug(raw) == expected)
        #expect(CMUXBuildSpace(devTag: raw)?.headerValue == "dev:\(expected)")
    }

    @Test("No usable tag means no build space", arguments: ["", "   ", "---", "\u{E9}\u{E9}"])
    func noSlug(raw: String) {
        #expect(CMUXBuildSpace.slug(raw) == nil)
        #expect(CMUXBuildSpace(devTag: raw) == nil)
    }

    @Test("A nil tag means no build space")
    func nilTag() {
        #expect(CMUXBuildSpace(devTag: nil) == nil)
    }

    @Test("A 64-character slug is kept; a 65-character one is rejected, not truncated")
    func lengthLimit() {
        let sixtyFour = String(repeating: "a", count: 64)
        #expect(CMUXBuildSpace(devTag: sixtyFour)?.slug == sixtyFour)
        #expect(CMUXBuildSpace(devTag: sixtyFour + "b") == nil)
        // The limit applies to the sanitized slug, not the raw tag.
        #expect(CMUXBuildSpace(devTag: "--" + sixtyFour + "--")?.slug == sixtyFour)
    }

    @Test("Every accepted value matches the backend's pattern")
    func matchesBackendPattern() throws {
        let pattern = try Regex("^dev:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$")
        for raw in ["My_Tag 2", "a", "x-1", String(repeating: "z9", count: 32), "Hello, World!"] {
            let value = try #require(CMUXBuildSpace(devTag: raw)).headerValue
            #expect(value.wholeMatch(of: pattern) != nil, "\(value)")
        }
    }

    @Test("apply(to:) sets X-Cmux-Build-Space on a request and a WebSocket upgrade")
    func applySetsHeader() throws {
        let space = try #require(CMUXBuildSpace(devTag: "My_Tag 2"))
        var http = URLRequest(url: try #require(URL(string: "https://cloud-api-staging.cmux.dev/v1/me")))
        space.apply(to: &http)
        #expect(http.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:my-tag-2")
        var socket = URLRequest(url: try #require(URL(string: "wss://cloud-api-staging.cmux.dev/v1/wire/socket")))
        space.apply(to: &socket)
        #expect(socket.value(forHTTPHeaderField: "x-cmux-build-space") == "dev:my-tag-2")
        #expect(space.headers == ["X-Cmux-Build-Space": "dev:my-tag-2"])
        #expect(CMUXBuildSpace.headerName == "X-Cmux-Build-Space")
    }
}
