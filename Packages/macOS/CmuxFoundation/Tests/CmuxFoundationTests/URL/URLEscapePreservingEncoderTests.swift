import Foundation
import Testing
@testable import CmuxFoundation

/// Covers ``URLEscapePreservingEncoder``: browser-style encoding of URL text
/// that keeps the `%XX` escapes it already has (manaflow-ai/cmux#40300).
@Suite("URL escape-preserving encoder")
struct URLEscapePreservingEncoderTests {
    private let encoder = URLEscapePreservingEncoder()

    @Test("All-ASCII text comes back unchanged, even with characters Foundation encodes")
    func asciiTextIsUnchanged() {
        let text = "https://example.com/a b?x=%2F&y=100%|z#a#b"
        #expect(encoder.encode(text) == text)
    }

    @Test("Raw Unicode is encoded and existing escapes are kept", arguments: [
        (
            "https://scrapbox.io/example-project/会議メモ_2026%2F11%2F5#section",
            "https://scrapbox.io/example-project/%E4%BC%9A%E8%AD%B0%E3%83%A1%E3%83%A2_2026%2F11%2F5#section"
        ),
        ("https://example.com/メモ%2f", "https://example.com/%E3%83%A1%E3%83%A2%2f"),
        ("https://example.com/🎉?q=%20", "https://example.com/%F0%9F%8E%89?q=%20"),
        (
            "obsidian://open?vault=メモ&file=2026%2F11%2F5",
            "obsidian://open?vault=%E3%83%A1%E3%83%A2&file=2026%2F11%2F5"
        )
    ])
    func encodesUnicodeAndKeepsEscapes(_ text: String, _ expected: String) {
        #expect(encoder.encode(text) == expected)
    }

    @Test("Next to raw Unicode, everything else a component can't carry is encoded too", arguments: [
        (
            "https://example.com/search?q=日本 語&next=a%2Fb",
            "https://example.com/search?q=%E6%97%A5%E6%9C%AC%20%E8%AA%9E&next=a%2Fb"
        ),
        ("https://example.com/日本100%", "https://example.com/%E6%97%A5%E6%9C%AC100%25"),
        ("https://example.com/メモ%2", "https://example.com/%E3%83%A1%E3%83%A2%252"),
        ("https://example.com/メモ|a[1]", "https://example.com/%E3%83%A1%E3%83%A2%7Ca%5B1%5D"),
        ("https://example.com/a#メモ#b?c", "https://example.com/a#%E3%83%A1%E3%83%A2%23b?c")
    ])
    func encodesOtherInvalidCharacters(_ text: String, _ expected: String) {
        #expect(encoder.encode(text) == expected)
    }

    @Test("The authority stays as written so Foundation can still convert IDN hosts", arguments: [
        ("https://日本語.jp/パス%2F", "https://日本語.jp/%E3%83%91%E3%82%B9%2F"),
        ("https://ユーザー@例え.jp:8443?q=メ", "https://ユーザー@例え.jp:8443?q=%E3%83%A1"),
        ("https://例え.jp#メ", "https://例え.jp#%E3%83%A1"),
        ("//日本.jp/パス", "//日本.jp/%E3%83%91%E3%82%B9")
    ])
    func leavesAuthorityAsWritten(_ text: String, _ expected: String) {
        #expect(encoder.encode(text) == expected)
    }

    @Test("Text without an authority is encoded throughout", arguments: [
        ("mailto:日本@example.com", "mailto:%E6%97%A5%E6%9C%AC@example.com"),
        ("localhost:8000/パス", "localhost:8000/%E3%83%91%E3%82%B9"),
        ("メモ%2F", "%E3%83%A1%E3%83%A2%2F")
    ])
    func encodesTextWithoutAuthority(_ text: String, _ expected: String) {
        #expect(encoder.encode(text) == expected)
    }

    @Test("Foundation finds nothing left to encode in the result", arguments: [
        "https://scrapbox.io/example-project/会議メモ_2026%2F11%2F5#section",
        "https://example.com/search?q=日本 語&next=a%2Fb",
        "https://example.com/日本100%",
        "https://example.com/メモ|a[1]",
        "https://example.com/a#メモ#b?c",
        "obsidian://open?vault=メモ&file=2026%2F11%2F5",
        "mailto:日本@example.com"
    ])
    func foundationKeepsEncodedText(_ text: String) throws {
        let encoded = encoder.encode(text)
        #expect(try #require(URL(string: encoded)).absoluteString == encoded)
        #expect(try #require(URLComponents(string: encoded)).string == encoded)
    }
}
