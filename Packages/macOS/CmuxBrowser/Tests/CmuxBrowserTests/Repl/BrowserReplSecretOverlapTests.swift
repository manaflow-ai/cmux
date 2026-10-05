import Foundation
import Testing

@testable import CmuxBrowser

/// Masking where matches overlap. Agent code can register any value, so it
/// can register one that overlaps a protected value it does not know (the
/// characters just before it, or a prefix it guessed): a match of that
/// value must never stop a protected value that intersects it from being
/// masked, within one store or across the stores a session masks with.
@Suite("Browser REPL secret overlaps")
struct BrowserReplSecretOverlapTests {
    private static let protected = "s3cr3t-value-0042"
    private static let suffix = "3cr3t-value-0042"
    private static let domains = [try! BrowserReplDomainPattern.parse("example.com", title: "test")]

    private func store(_ entries: [(name: String, value: String)]) throws -> BrowserReplSecretStore {
        let store = BrowserReplSecretStore()
        for entry in entries {
            try store.set(name: entry.name, value: entry.value, domains: ["example.com"], totp: false, title: "t")
        }
        return store
    }

    @Test("A value that ends inside a protected value does not leave its suffix unmasked")
    func earlierOverlapMasksTheUnion() throws {
        let store = try store([("key", Self.protected), ("known", "Xs")])
        let text = "file: Xs3cr3t-value-0042 end"
        let redacted = store.redact(text)
        #expect(!redacted.contains(Self.suffix), "\(redacted)")
        #expect(redacted.hasPrefix("file: <secret:"), "\(redacted)")
        #expect(redacted.hasSuffix("> end"), "\(redacted)")
        let bytes = try store.redact(Data(text.utf8))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(Self.suffix))
        // Encoded forms overlap the same way.
        #expect(!store.redact("a=%58s3cr3t-value-0042").contains(Self.suffix))
    }

    @Test("A retired value stays masked under an overlapping match")
    func retiredValueStaysMaskedUnderOverlap() throws {
        let store = try store([("key", Self.protected)])
        store.delete("key")
        try store.set(name: "known", value: "Xs", domains: ["example.com"], totp: false, title: "t")
        #expect(!store.redact("Xs3cr3t-value-0042").contains(Self.suffix))
    }

    @Test("A chain of overlapping matches is masked as one span")
    func chainOfOverlapsIsOneSpan() throws {
        let store = try store([("a", "abcd"), ("b", "cdef"), ("c", "efgh")])
        let redacted = store.redact("[abcdefgh]")
        #expect(redacted.hasPrefix("[<secret:"), "\(redacted)")
        #expect(redacted.hasSuffix(">]"), "\(redacted)")
        for letter in "abcdefgh" { #expect(!redacted.dropFirst(9).dropLast(2).contains("\(letter)\(letter)")) }
        #expect(!redacted.contains("gh]"), "\(redacted)")
        // Adjacent matches of one value stay a single mask; others stay apart.
        #expect(store.redact("abcdabcd") == "<secret:a>")
        #expect(store.redact("abcd efgh") == "<secret:a> <secret:c>")
    }

    @Test("A Base64 run whose decoded value is masked does not hide a value that runs past it")
    func valueRunningPastABase64MatchIsMasked() throws {
        let encoded = Data("pin-4821-long".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let tail = String(encoded.suffix(3)) + "!tail-secret"
        let store = try store([("pin", "pin-4821-long"), ("tail", tail)])
        let redacted = store.redact("t=\(encoded)!tail-secret.")
        #expect(!redacted.contains("tail-secret"), "\(redacted)")
    }
}
