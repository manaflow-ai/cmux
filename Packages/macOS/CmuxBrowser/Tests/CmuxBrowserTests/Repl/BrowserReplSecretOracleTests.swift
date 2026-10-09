import Foundation
import Testing

@testable import CmuxBrowser

/// Masking runs over data the agent chooses (what it prints, writes or has
/// a page echo), so a mask that appears only where the data equals a held
/// value tells the agent which of its guesses was the value. A value from
/// a small set (a TOTP code, a short PIN) is guessed whole in one call, so
/// such values are masked by their shape, never by comparison.
@Suite("Browser REPL secret masking oracle")
struct BrowserReplSecretOracleTests {
    /// RFC 6238's test key, base32.
    private static let totpSeed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    @Test("Guessed six-digit numbers are all masked alike while a TOTP secret is held, the valid code among them")
    func totpCodesAreNotAnOracle() throws {
        let store = BrowserReplSecretStore()
        try store.set(name: "otp", value: Self.totpSeed, domains: ["example.com"], totp: true, title: "t")
        let code = BrowserReplSecretStore.totp(key: try #require(BrowserReplSecretStore.base32Decode(Self.totpSeed)), time: Date().timeIntervalSince1970)
        let guesses = ["000001", "123456", code, "999998", "287081"]
        let masked = store.redact(guesses.joined(separator: " "))
        #expect(masked == Array(repeating: "<secret:otp>", count: guesses.count).joined(separator: " "), "\(masked)")
        // A file the agent writes and reads back is masked by the same rule.
        let boundary = BrowserReplBoundary()
        try boundary.secrets.set(name: "otp", value: Self.totpSeed, domains: ["example.com"], totp: true, title: "t")
        let write = try #require(boundary.fileStoreRedaction(syscall: "write"))
        let file = String(decoding: try write(Data("000001,\(code),999998".utf8)), as: UTF8.self)
        #expect(!file.contains(code) && !file.contains("000001") && !file.contains("999998"), "\(file)")
    }

    @Test("Guesses of a short digit-only secret are all masked alike, as text and as JSON numbers")
    func shortNumericSecretIsNotAnOracle() throws {
        let store = BrowserReplSecretStore()
        try store.set(name: "pin", value: "4821", domains: ["example.com"], totp: false, title: "t")
        #expect(store.redact("4820 4821 4822") == "<secret:pin> <secret:pin> <secret:pin>")
        let numbers = JSONSerialization.browserReplValue(store.redactJSON("[4820,4821,4822]")) as? [Any] ?? []
        let forms = numbers.map { "\($0)" }
        #expect(Set(forms).count == 1, "\(forms)")
        // Base64 of each guess is treated alike too.
        let encoded = ["4820", "4821", "4822"].map { Data($0.utf8).base64EncodedString() }
        let redacted = store.redact(encoded.joined(separator: " ")).split(separator: " ").map(String.init)
        #expect(redacted.count == 3 && (redacted == encoded || Set(redacted).count == 1), "\(redacted)")
    }

    @Test("A code another session typed is masked by its shape in a reader's output")
    func typedCodeIsNotAnOracle() throws {
        let typed = BrowserReplSecretStore()
        try typed.setLiteral(key: "typed-1", maskName: "otp", value: "287082", domains: [])
        let boundary = BrowserReplBoundary(typedSecrets: { typed })
        let shown = boundary.egress(.text("287081 287082 287083")).text
        #expect(shown == "<secret:otp> <secret:otp> <secret:otp>", "\(shown)")
    }

    /// Replaced TOTP secrets stay masked (their codes stay valid), so a
    /// session can hold 1,024 of them. Masking a long text of numbers must
    /// still take time linear in its length, not in its numbers times the
    /// codes.
    @Test("Masking numbers stays linear with a thousand TOTP secrets held")
    func manyTOTPSecretsStayLinear() throws {
        let store = BrowserReplSecretStore()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        for index in 0..<BrowserReplSecretStore.maximumValuesPerSession {
            var seed = "GEZDGNBVGY3TQOJQ"
            var rest = index
            for _ in 0..<4 {
                seed.append(alphabet[rest % 32])
                rest /= 32
            }
            try store.set(name: "otp", value: seed, domains: ["example.com"], totp: true, title: "t")
        }
        let text = String(repeating: "12345 ", count: 200_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = store.redact(text) }
        #expect(elapsed < .seconds(5), "\(elapsed)")
    }
}
