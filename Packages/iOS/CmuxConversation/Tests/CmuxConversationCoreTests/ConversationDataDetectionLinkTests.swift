import Foundation
import Testing
@testable import CmuxConversationCore

/// Lawrence 2026-10-23: the Cloud Chief wrote `**https://github.com/login/device**`; the bubble
/// shows Markdown as written, and the system detector takes the closing `**` into the URL, so a
/// tap opened `https://github.com/login/device**`. A detected link ends before Markdown marks.
@Suite struct ConversationDataDetectionLinkTests {
    func links(_ text: String) -> [(String, String?)] {
        let ns = text as NSString
        return ConversationDataDetection.items(in: text).map { (ns.substring(with: $0.range), $0.url?.absoluteString) }
    }

    @Test func aBoldURLOpensWithoutTheStars() {
        let found = links("Open **https://github.com/login/device** now")
        #expect(found.count == 1)
        #expect(found.first?.0 == "https://github.com/login/device")
        #expect(found.first?.1 == "https://github.com/login/device")
    }

    @Test func aURLInCodeOrItalicOpensWithoutTheMarks() {
        #expect(links("`https://a.com/b`").map(\.1) == ["https://a.com/b"])
        #expect(links("_https://a.com/b_ and ~~https://c.com/d~~").map(\.1) == ["https://a.com/b", "https://c.com/d"])
    }

    @Test func aPlainURLIsUnchanged() {
        #expect(links("see https://github.com/x/y/pull/1.").map(\.1) == ["https://github.com/x/y/pull/1"])
        #expect(links("https://example.com/a_b_c").map(\.1) == ["https://example.com/a_b_c"])
    }
}
