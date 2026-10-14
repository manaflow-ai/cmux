import Foundation
import Testing

@testable import CmuxBrowser

/// Redaction of secret values on the native side for the forms the boundary
/// tests do not cover: generated TOTP codes, binary fetch bodies and files
/// read back through `fs`.
@Suite("Browser REPL secret redaction", .serialized)
struct BrowserReplSecretRedactionTests {
    private static let value = "v4lue-xyz-7731"
    /// RFC 6238's test key, base32.
    private static let totpSeed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    private func makeSession(_ driver: ScriptedPageDriver, cwd: String = FileManager.default.temporaryDirectory.path) -> BrowserReplSession? {
        guard let bundle = try? browserReplRepositoryBundle() else { return nil }
        return BrowserReplSession(id: "redaction-\(UUID().uuidString)", cwd: cwd, bundle: bundle, driver: driver)
    }

    private func run(_ session: BrowserReplSession, _ code: String) async -> BrowserReplEvalResult? {
        await browserReplWithDeadline(seconds: 60) { await session.evaluate(code: code, timeout: .seconds(30)) }
    }

    private func spelled(_ text: String) -> String {
        text.map(String.init).joined(separator: " ")
    }

    @Test("A generated TOTP code is redacted from results and masked in captures while it is valid")
    func totpCodeIsRedactedAndMasked() async throws {
        let driver = ScriptedPageDriver()
        let code = currentCode()
        driver.pageValue = ["text": "code \(code) sent", "number": Int(code) ?? 0]
        let session = try #require(makeSession(driver))
        defer { session.close() }
        let result = await run(session, """
        secrets.set("otp", "\(Self.totpSeed)", { domains: ["example.com"], totp: true });
        await page.goto("https://example.com/login");
        const read = await page.evaluate(() => 1);
        console.log(JSON.stringify(read).split("").join(" "));
        console.log(read.text.includes("<secret:otp>"), String(read.number).includes("<secret:otp>"));
        await page.screenshot().catch(() => {});
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(result?.error == nil, "\(result?.error ?? "")")
        #expect(!output.contains(spelled(code)), "\(output)")
        #expect(output.contains("true true"), "\(output)")
        let masks = driver.params("tab.screenshot").first?["secretMasks"] as? [[String: Any]] ?? []
        let masked = masks.filter { ($0["value"] as? String) == code }
        #expect(!masked.isEmpty, "\(masks.map { $0["value"] ?? "" })")
        #expect(masked.allSatisfy { (($0["domains"] as? [[String: Any]]) ?? []).contains { $0["host"] as? String == "example.com" } })
    }

    @Test("A secret in a binary fetch body is redacted before JavaScript sees the bytes")
    func binaryFetchBodyIsRedacted() async throws {
        let value = Self.value
        let server = try BrowserReplTestHTTPServer { _, _, _ in
            var body = Data([0xff, 0x00, 0xfe])
            body.append(Data(value.utf8))
            body.append(Data([0x00, 0x80]))
            return (200, ["Content-Type": "application/octet-stream"], body)
        }
        try await server.start()
        defer { server.stop() }
        let session = try #require(makeSession(ScriptedPageDriver()))
        defer { session.close() }
        let result = await run(session, """
        secrets.set("k", "\(value)", { domains: ["example.com"] });
        const bytes = new Uint8Array(await (await fetch("http://127.0.0.1:\(server.port)/blob")).arrayBuffer());
        const text = Array.from(bytes, (b) => String.fromCharCode(b)).join("");
        console.log(text.split("").join(" "));
        console.log("masked", text.includes("<secret:k>"), bytes[0], bytes[bytes.length - 1]);
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(result?.error == nil, "\(result?.error ?? "")")
        #expect(!output.contains(spelled(value)), "\(output)")
        #expect(output.contains("masked true 255 128"), "\(output)")
    }

    @Test("fs.readFile returns a loaded secret's value masked, from text and from bytes")
    func readFileIsRedacted() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-redaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data(#"{"example.com":{"pw":"\#(Self.value)"}}"#.utf8).write(to: work.appendingPathComponent("secrets.json"))
        var blob = Data([0xff, 0x00])
        blob.append(Data(Self.value.utf8))
        blob.append(Data([0x80]))
        try blob.write(to: work.appendingPathComponent("blob.bin"))
        let session = try #require(makeSession(ScriptedPageDriver(), cwd: work.path))
        defer { session.close() }
        let result = await run(session, """
        const fs = await import("node:fs");
        secrets.load("./secrets.json");
        const text = fs.readFileSync("./secrets.json", "utf8");
        console.log(text.split("").join(" "));
        const bytes = fs.readFileSync("./blob.bin");
        const latin = Array.from(bytes, (b) => String.fromCharCode(b)).join("");
        console.log(latin.split("").join(" "));
        console.log("masked", text.includes("<secret:pw>"), latin.includes("<secret:pw>"), bytes[0], bytes[bytes.length - 1]);
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(result?.error == nil, "\(result?.error ?? "")")
        #expect(!output.contains(spelled(Self.value)), "\(output)")
        #expect(output.contains("masked true true 255 128"), "\(output)")
    }

    private func currentCode() -> String {
        BrowserReplSecretStore.totp(key: BrowserReplSecretStore.base32Decode(Self.totpSeed) ?? Data(), time: Date().timeIntervalSince1970)
    }
}
