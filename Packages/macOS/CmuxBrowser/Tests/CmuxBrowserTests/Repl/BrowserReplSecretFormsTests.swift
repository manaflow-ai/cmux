import Foundation
import Testing

@testable import CmuxBrowser

/// The secret store's redaction on hostile input: its cost and memory stay
/// bounded, and a value is found in the encodings a page or a server can
/// hand back (Base64 at any offset, JSON and HTML escapes).
@Suite("Browser REPL secret forms", .serialized)
struct BrowserReplSecretFormsTests {
    private static let longName = String(repeating: "n", count: 64)

    private func makeSession() throws -> BrowserReplSession {
        BrowserReplSession(
            id: "forms-\(UUID().uuidString)",
            cwd: FileManager.default.temporaryDirectory.path,
            bundle: try browserReplRepositoryBundle(),
            driver: ScriptedPageDriver()
        )
    }

    private func run(_ session: BrowserReplSession, _ code: String) async -> BrowserReplEvalResult? {
        await browserReplWithDeadline(seconds: 120) { await session.evaluate(code: code, timeout: .seconds(90)) }
    }

    /// A one-character secret with a 64-character name: each occurrence in
    /// a 1 MiB body grows 73 times when masked. The session must not build
    /// that (37 MiB here, gigabytes for the 64 MiB a fetch may return); it
    /// refuses with a clear error, and an output line says it was withheld.
    @Test("Masking cannot blow a bounded body up into a huge allocation")
    func maskingGrowthIsBounded() async throws {
        let body = Data(String(repeating: "Z,", count: 1 << 19).utf8)
        let server = try BrowserReplTestHTTPServer { _, _, _ in
            (200, ["Content-Type": "text/plain"], body)
        }
        try await server.start()
        defer { server.stop() }
        let session = try makeSession()
        defer { session.close() }
        let result = await run(session, """
        secrets.set("\(Self.longName)", "Z", { domains: ["example.com"] });
        try {
          const text = await (await fetch("http://127.0.0.1:\(server.port)/big")).text();
          console.log("fetched", text.length);
        } catch (error) {
          console.log("refused", String(error.message).includes("limit"));
        }
        console.log("Z,".repeat(1 << 19));
        """)
        let lines = result?.lines.map(\.text) ?? []
        #expect(result?.error == nil, "\(result?.error ?? "")")
        #expect(lines.contains("refused true"), "\(lines.map { String($0.prefix(200)) })")
        #expect(lines.allSatisfy { $0.utf8.count < 9 << 20 }, "an output line grew past the limit")
        #expect(lines.contains { $0.contains("withheld") }, "\(lines.map { String($0.prefix(200)) })")
    }

    /// Every redaction scans for every secret, so the store a script fills
    /// must stay bounded: in count, in each value's length and in each
    /// secret's domains. Each refusal says the limit.
    @Test("A session holds at most 256 secrets of at most 4 KiB with at most 64 domains each")
    func secretStoreIsBounded() throws {
        let store = BrowserReplSecretStore()
        func refusal(_ name: String, _ value: String, domains: [String] = ["example.com"]) -> String? {
            do {
                try store.set(name: name, value: value, domains: domains, totp: false, title: "secrets.set")
                return nil
            } catch {
                return (error as? BrowserReplDriverError)?.message ?? "\(error)"
            }
        }
        for index in 0..<256 {
            #expect(refusal("s\(index)", "value-\(index)") == nil)
        }
        // Replacing a secret is not another one.
        #expect(refusal("s0", "replaced") == nil)
        let tooMany = try #require(refusal("s256", "value-256"), "a 257th secret was accepted")
        #expect(tooMany.contains("256"), "\(tooMany)")
        #expect(store.delete("s1"))
        #expect(refusal("s256", "value-256") == nil)

        #expect(refusal("s0", String(repeating: "v", count: 4096)) == nil)
        let tooLong = try #require(refusal("s0", String(repeating: "v", count: 4097)), "a 4097-byte value was accepted")
        #expect(tooLong.contains("4096"), "\(tooLong)")
        let manyDomains = (0..<65).map { "d\($0).example.com" }
        let tooManyDomains = try #require(refusal("s0", "v", domains: manyDomains), "65 domains were accepted")
        #expect(tooManyDomains.contains("64"), "\(tooManyDomains)")
    }

    /// 256 values of 4 KiB that share all but their last bytes, against
    /// text made of that shared prefix: each position starts a match of
    /// every value that runs 4 KiB before it fails. Masking must still end
    /// in time linear in the text (masked, unchanged, or withheld), never
    /// in time proportional to the text times every value's length.
    @Test("Masking stays bounded in the text's length with many long secrets that share a prefix")
    func sharedPrefixSecretsStayBounded() async throws {
        let store = BrowserReplSecretStore()
        let prefix = String(repeating: "a", count: 4090)
        for index in 0..<256 {
            try store.set(name: "s\(index)", value: prefix + String(format: "%03d", index), domains: ["example.com"], totp: false, title: "t")
        }
        let text = String(repeating: "a", count: 1 << 16)

        let redacted = await browserReplWithDeadline(seconds: 20) { store.redact(text) }

        let result = try #require(redacted, "masking 64 KiB took more than 20 s")
        #expect(result == text || result.contains("withheld"), "\(result.prefix(200))")
        // A value in the text is still masked.
        #expect(store.redact("x " + prefix + "007 y") == "x <secret:s7> y")
    }

    /// Base64 a page or server hands back: of a value too short for an
    /// eight-character run (a PIN), at each of the three offsets that put a
    /// value's encoding out of step with the run it sits in (`"x" +
    /// btoa(value)`), and base64url without padding.
    @Test("Base64 of a short value, out of step inside a longer run, or base64url, is masked")
    func base64FormsAreMasked() throws {
        let store = BrowserReplSecretStore()
        try store.set(name: "pin", value: "4821", domains: ["example.com"], totp: false, title: "t")
        try store.set(name: "code", value: "a7Q", domains: ["example.com"], totp: false, title: "t")
        try store.set(name: "pw", value: "v4lue-xyz-7731", domains: ["example.com"], totp: false, title: "t")
        try store.set(name: "url", value: "k?~>~?k-secret", domains: ["example.com"], totp: false, title: "t")
        let pw = Data("v4lue-xyz-7731".utf8).base64EncodedString()
        let samples: [(text: String, hidden: String, mask: String)] = [
            ("pin=NDgyMQ==", "NDgyMQ", "<secret:pin>"),
            (#"{"pin":"NDgyMQ"}"#, "NDgyMQ", "<secret:pin>"),
            ("c=YTdR;", "YTdR", "<secret:code>"),
            ("t=Q\(pw)", String(pw.dropLast()), "<secret:pw>"),
            ("t=QU\(pw)", String(pw.dropLast()), "<secret:pw>"),
            ("t=QUJ\(pw)", String(pw.dropLast()), "<secret:pw>"),
            ("t=YWI\(pw)", String(pw.dropLast()), "<secret:pw>"),
            ("u=az9-Pn4_ay1zZWNyZXQ", "az9-Pn4_ay1zZWNyZXQ", "<secret:url>"),
        ]
        for sample in samples {
            let redacted = store.redact(sample.text)
            #expect(redacted.contains(sample.mask), "\(sample.text) -> \(redacted)")
            #expect(!redacted.contains(sample.hidden), "\(sample.text) -> \(redacted)")
        }
        // Words and other Base64 stay.
        let plain = "Mxyz NDgy abcdEFGH QYTd the quick brown fox " + Data((0..<3000).map { UInt8($0 % 256) }).base64EncodedString()
        #expect(store.redact(plain) == plain)
    }

    /// Escapes other serializers and markup use: JSON `\\uXXXX` for any
    /// character (Python's `ensure_ascii`, Go's HTML-safe JSON), surrogate
    /// pairs, JavaScript `\\xHH` and `\\u{...}`, HTML numeric character
    /// references (decimal, hex, without the semicolon), named references
    /// in upper case, `%uXXXX` (JavaScript's `escape`) and a value
    /// percent-encoded twice (a URL inside a redirect parameter).
    @Test("JSON, JavaScript, HTML and doubled percent escapes of a value are masked")
    func escapedFormsAreMasked() throws {
        let value = "p@ss w/rd:\u{E9}\u{1F600}"
        let store = BrowserReplSecretStore()
        try store.set(name: "pw", value: value, domains: ["example.com"], totp: false, title: "t")
        try store.set(name: "amp", value: "a&b<c", domains: ["example.com"], totp: false, title: "t")
        func each(_ form: (Unicode.Scalar) -> String) -> String { value.unicodeScalars.map(form).joined() }
        func utf16(_ scalar: Unicode.Scalar, _ format: String) -> String {
            String(scalar).utf16.map { String(format: format, $0) }.joined()
        }
        let percentTwice = value.utf8.map { String(format: "%%25%02X", $0) }.joined()
        let samples = [
            each { utf16($0, "\\u%04x") },
            each { utf16($0, "\\u%04X") },
            each { $0.isASCII ? String($0) : utf16($0, "\\u%04x") },
            each { $0.value < 0x100 ? String(format: "\\x%02x", $0.value) : String(format: "\\u{%X}", $0.value) },
            each { "&#\($0.value);" },
            each { String(format: "&#x%X;", $0.value) },
            each { String(format: "&#X%05x", $0.value) },
            each { $0.value < 0x100 ? String(format: "%%u%04X", $0.value) : String($0) },
            percentTwice,
            "a&AMP;b&LT;c a&#38b&#60c",
        ]
        for sample in samples {
            let redacted = store.redact(" \(sample) ")
            #expect(redacted == " <secret:pw> " || redacted.hasPrefix(" <secret:amp> "), "\(sample) -> \(redacted)")
        }
        #expect(store.redact("a&AMP;b&LT;c a&#38b&#60c") == "<secret:amp> <secret:amp>")
        #expect(store.redact("&#112; \\u0070 &amp;") == "&#112; \\u0070 &amp;")
    }
}
