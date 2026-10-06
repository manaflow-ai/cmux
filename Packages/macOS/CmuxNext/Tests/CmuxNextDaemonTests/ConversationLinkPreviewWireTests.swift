import Foundation
import Testing
@testable import CmuxNextDaemon

/// Wire shape of a `link_preview` part (cmux-tui spec/commands.md): the
/// preview its sender fetched, in snake_case, with optional fields absent.
@Suite struct ConversationLinkPreviewWireTests {
    @Test func aLinkPreviewPartRoundTripsWithItsImage() throws {
        let hash = String(repeating: "a", count: 64)
        let json = #"{"type":"link_preview","url":"https://example.com/post","title":"A post","site":"example.com","image":{"hash":"\#(hash)","mime_type":"image/jpeg","byte_count":2048}}"#
        let part = try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
        let expected = ConversationLinkPreview(url: "https://example.com/post", title: "A post", site: "example.com",
                                               image: ConversationDerivedImage(hash: hash, mimeType: "image/jpeg", byteCount: 2048))
        #expect(part == .linkPreview(expected))
        #expect(part.plainText == "A post")
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(part))
        let original = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(encoded == original)
    }

    @Test func aBareLinkPreviewKeepsOnlyItsURLAndShowsIt() throws {
        let json = #"{"type":"link_preview","url":"http://example.com"}"#
        let part = try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
        #expect(part == .linkPreview(ConversationLinkPreview(url: "http://example.com")))
        #expect(part.plainText == "http://example.com")
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(part))
        #expect(encoded == .object(["type": .string("link_preview"), "url": .string("http://example.com")]))
    }
}
