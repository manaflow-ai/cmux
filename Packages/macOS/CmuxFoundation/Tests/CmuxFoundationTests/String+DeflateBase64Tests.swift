import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct StringDeflateBase64Tests {
    @Test func roundTripsASCII() {
        let original = "export CMUX_SOCKET_PATH=127.0.0.1:64003\nhash -r >/dev/null 2>&1 || true\n"
        let encoded = try? #require(original.deflatedBase64)
        let decoded = encoded.flatMap { String(deflatedBase64: $0) }
        #expect(decoded == original)
    }

    @Test func roundTripsUnicodeAndControlCharacters() {
        let original = "printf '\\n\\033[33m[cmux] reconnecting…\\033[0m\\n' — 日本語 — \u{0007}"
        let encoded = try? #require(original.deflatedBase64)
        let decoded = encoded.flatMap { String(deflatedBase64: $0) }
        #expect(decoded == original)
    }

    @Test func emptyStringEncodesToNil() {
        #expect("".deflatedBase64 == nil)
    }

    @Test func invalidBase64DecodesToNil() {
        #expect(String(deflatedBase64: "not valid base64 @@@") == nil)
    }

    @Test func nonZlibPayloadDecodesToNil() {
        // Valid base64, but the bytes are not a zlib stream.
        let plainBase64 = Data("hello world".utf8).base64EncodedString()
        #expect(String(deflatedBase64: plainBase64) == nil)
    }

    @Test func oversizedDecodedPayloadDecodesToNil() {
        let payload = String(repeating: "x", count: 1024)
        let encoded = try? #require(payload.deflatedBase64)
        #expect(encoded.flatMap { String(deflatedBase64: $0, maxDecodedByteCount: 1023) } == nil)
        #expect(encoded.flatMap { String(deflatedBase64: $0, maxDecodedByteCount: 1024) } == payload)
    }

    @Test func compressesRepetitiveShellPayloadFarBelowPlainBase64() {
        // A bootstrap-shaped payload (lots of repeated shell structure) must shrink
        // dramatically versus plain base64 — that shrinkage is the whole point of the
        // codec for SSH argv (manaflow-ai/cmux#6738).
        var lines: [String] = []
        for index in 0..<1500 {
            lines.append("export CMUX_VAR_\(index)=\"value for variable number \(index)\"")
            lines.append("if [ \"${CMUX_VAR_\(index):-}\" != \"0\" ]; then printf '%s\\n' \"\(index)\"; fi")
        }
        let payload = lines.joined(separator: "\n")
        let plainBase64Length = Data(payload.utf8).base64EncodedString().count
        let encoded = try? #require(payload.deflatedBase64)
        let encodedLength = try? #require(encoded?.count)
        #expect((encodedLength ?? .max) < plainBase64Length / 4)
        #expect(encoded.flatMap { String(deflatedBase64: $0) } == payload)
    }
}
