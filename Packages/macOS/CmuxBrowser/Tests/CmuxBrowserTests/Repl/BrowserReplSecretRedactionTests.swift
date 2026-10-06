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

    private func makeSession(_ driver: any BrowserReplDriver, cwd: String = browserReplTestWorkingDirectory) -> BrowserReplSession? {
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
        // A code read as a number is masked when it keeps its six digits; one
        // with a leading zero reads as a shorter number, which masking by shape
        // leaves (masking every shorter number would mask every small number).
        console.log(read.text.includes("<secret:otp>"), String(read.number).includes("<secret:otp>") || (typeof read.number === "number" && String(read.number).length < 6));
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

    /// Deleting, clearing or replacing a secret stops it from being typed,
    /// but a value the session held stays masked for the session's life: the
    /// agent never saw it, and the file it was loaded from is still there.
    @Test("A deleted, cleared or replaced secret's value stays masked in files read back, output and captures")
    func retiredSecretValuesStayMasked() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-retired-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let values = ["v4lue-deleted-1", "v4lue-cleared-2", "v4lue-replaced-3"]
        try Data(#"{"example.com":{"gone":"\#(values[0])","later":"\#(values[1])","swapped":"\#(values[2])"}}"#.utf8)
            .write(to: work.appendingPathComponent("secrets.json"))
        let driver = ScriptedPageDriver()
        let session = try #require(makeSession(driver, cwd: work.path))
        defer { session.close() }
        let result = await run(session, """
        const fs = await import("node:fs");
        secrets.load("./secrets.json");
        secrets.delete("gone");
        secrets.set("swapped", "another-value-4", { domains: ["example.com"] });
        const afterDelete = fs.readFileSync("./secrets.json", "utf8");
        secrets.clear();
        const afterClear = fs.readFileSync("./secrets.json", "utf8");
        console.log(afterDelete.split("").join(" "));
        console.log(afterClear.split("").join(" "));
        console.log("masked", afterClear.includes("<secret:gone>"), afterClear.includes("<secret:later>"), afterClear.includes("<secret:swapped>"));
        console.log(afterClear);
        console.log(secrets.list().length, secrets.has("gone"));
        await page.goto("https://example.com/login");
        await page.screenshot().catch(() => {});
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(result?.error == nil, "\(result?.error ?? "")")
        for value in values {
            #expect(!output.contains(spelled(value)), "\(value) was shown after its secret went: \(output)")
            #expect(!output.contains(value), "\(value) was shown after its secret went: \(output)")
        }
        #expect(output.contains("masked true true true"), "\(output)")
        // Gone for typing and listing.
        #expect(output.contains("0 false"), "\(output)")
        let masks = driver.params("tab.screenshot").first?["secretMasks"] as? [[String: Any]] ?? []
        let maskedValues = Set(masks.compactMap { $0["value"] as? String })
        #expect(maskedValues.isSuperset(of: values), "\(maskedValues)")
    }

    /// Session A typed a secret into a tab; session B (`tabs.use`) does not
    /// hold it. Every output B's own secrets are masked in (fetch bodies
    /// read with the tab's cookies, files B writes and reads back, a page's
    /// download, output lines, the cell's error) masks A's value too, not
    /// only driver results and events.
    @Test("A secret another session typed into a tab is masked in fetch, fs, output and errors")
    func anotherSessionsTypedSecretIsRedactedOutsideDriverResults() async throws {
        let value = Self.value
        let server = try BrowserReplTestHTTPServer { path, _, _ in
            if path == "/blob" {
                var body = Data([0xff, 0x00])
                body.append(Data(value.utf8))
                body.append(Data([0x80]))
                return (200, ["Content-Type": "application/octet-stream"], body)
            }
            return (200, ["Content-Type": "application/json", "X-Echo": value], Data(#"{"password":"\#(value)"}"#.utf8))
        }
        try await server.start()
        defer { server.stop() }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-typed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data("download: \(value)\n".utf8).write(to: work.appendingPathComponent("download.txt"))
        let typed = BrowserReplSecretStore()
        try typed.setLiteral(key: "typed-1", maskName: "password", value: value, domains: [])
        let session = try #require(makeSession(TypedSecretsPageDriver(typed: typed), cwd: work.path))
        defer { session.close() }
        let result = await run(session, """
        const fs = await import("node:fs");
        const response = await fetch("http://127.0.0.1:\(server.port)/profile");
        const json = await response.text();
        console.log("fetch", json.split("").join(" "), response.headers.get("x-echo").split("").join(" "));
        const bytes = new Uint8Array(await (await fetch("http://127.0.0.1:\(server.port)/blob")).arrayBuffer());
        console.log("binary", Array.from(bytes, (b) => String.fromCharCode(b)).join("").split("").join(" "));
        console.log("file", fs.readFileSync("./download.txt", "utf8").split("").join(" "));
        fs.writeFileSync("./written.txt", "\(value)");
        console.log("line \(value)");
        throw new Error("failed with \(value)");
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(!output.contains(spelled(value)), "\(output)")
        #expect(!output.contains(value), "\(output)")
        #expect(output.contains("line <secret:password>"), "\(output)")
        #expect(output.components(separatedBy: spelled("<secret:password>")).count - 1 >= 4, "\(output)")
        let error = result?.error ?? ""
        #expect(error.contains("<secret:password>") && !error.contains(value), "\(error)")
        let written = try String(contentsOf: work.appendingPathComponent("written.txt"), encoding: .utf8)
        #expect(written == "<secret:password>", "\(written)")
    }

    /// A capture's masks are the session's secret values when the call is
    /// made; the same session can meanwhile set a new secret and type it
    /// while the capture is taken (calls run concurrently), and that value
    /// is not among the masks. The capture is refused (`stale`) instead of
    /// returning pixels that may show it.
    @Test("A capture taken while the session sets and types a new secret is refused")
    func aCaptureDuringANewOwnSecretIsRefused() async throws {
        let driver = HeldCaptureDriver()
        let session = try #require(makeSession(driver))
        defer { session.close() }
        // The driver holds the capture, and says so to page reads, until
        // the new secret is typed.
        let result = await run(session, """
        secrets.set("a", "\(Self.value)", { domains: ["example.com"] });
        await page.goto("https://example.com/login");
        const shot = page.screenshot().then(() => "captured", (e) => "refused " + (e.code || e.message));
        while ((await page.evaluate(() => 0)) !== "capturing") {}
        secrets.set("b", "n3w-value-5521", { domains: ["example.com"] });
        await page.locator("#f").fill(secret("b"), { timeout: 2000 });
        console.log(await shot);
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(result?.error == nil, "\(result?.error ?? "")")
        #expect(driver.page.typedInto.contains { $0.text == "n3w-value-5521" }, "the new secret was not typed, so this tests nothing")
        #expect(output.hasPrefix("refused stale"), "the capture returned pixels taken while a secret its masks lacked was typed: \(output)")
    }

    @Test("A capture taken while the session's secrets stay as they were returns its pixels")
    func aCaptureWithTheSameSecretsReturnsItsPixels() async throws {
        let driver = ScriptedPageDriver()
        let session = try #require(makeSession(driver))
        defer { session.close() }
        let result = await run(session, """
        secrets.set("a", "\(Self.value)", { domains: ["example.com", "*.example.org", "https://login.example.net:8443"] });
        secrets.set("otp", "\(Self.totpSeed)", { domains: ["example.com"], totp: true });
        await page.goto("https://example.com/login");
        console.log(await page.screenshot().then(() => "captured", (e) => "refused " + (e.code || e.message)));
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(output == "captured", "\(output)")
    }

    /// A file the session did not write (a page's download, a secrets file)
    /// can hold a secret in the clear. `fs.copyFile` writes a new file, so,
    /// like `writeFile`, it writes the secret masked: the copy is a file a
    /// tab may load from the session's directories, where capture masks for
    /// the secret's domains do not apply.
    @Test("fs.copyFile writes a secret held in its source masked, text and bytes")
    func copyFileIsRedacted() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data("download: \(Self.value)\n".utf8).write(to: work.appendingPathComponent("download.txt"))
        var blob = Data([0xff, 0x00])
        blob.append(Data(Self.value.utf8))
        blob.append(Data([0x80]))
        try blob.write(to: work.appendingPathComponent("blob.bin"))
        let session = try #require(makeSession(ScriptedPageDriver(), cwd: work.path))
        defer { session.close() }
        let result = await run(session, """
        const fs = await import("node:fs");
        secrets.set("pw", "\(Self.value)", { domains: ["example.com"] });
        fs.copyFileSync("./download.txt", "./copy.txt");
        fs.copyFileSync("./blob.bin", "./copy.bin");
        console.log("copied");
        """)
        #expect(result?.error == nil, "\(result?.error ?? "")")
        let text = try String(contentsOf: work.appendingPathComponent("copy.txt"), encoding: .utf8)
        #expect(text == "download: <secret:pw>\n", "\(text)")
        let bytes = try Data(contentsOf: work.appendingPathComponent("copy.bin"))
        var expected = Data([0xff, 0x00])
        expected.append(Data("<secret:pw>".utf8))
        expected.append(Data([0x80]))
        #expect(bytes == expected, "\(Array(bytes))")
    }

    /// File reads mask a loaded value by its UTF-8 bytes and their escaped
    /// forms (except a short digit value's, masked by shape). A source in
    /// another encoding, or one that spells a digit value with JSON escapes,
    /// would come back from `fs.readFile` with the value readable, so either
    /// `secrets.load` refuses it or the value read back is masked.
    @Test("A secrets file fs reads back never shows a loaded value in another encoding or escaped form")
    func encodedSourceIsNeverReadBackUnmasked() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-encoded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let json = #"{"example.com":{"pw":"\#(Self.value)"}}"#
        var utf16 = Data([0xff, 0xfe])
        utf16.append(json.data(using: .utf16LittleEndian) ?? Data())
        try utf16.write(to: work.appendingPathComponent("utf16.json"))
        try (json.data(using: .utf32BigEndian) ?? Data()).write(to: work.appendingPathComponent("utf32.json"))
        // 4271, each digit escaped.
        try Data(#"{"example.com":{"pin":"\u0034\u0032\u0037\u0031"}}"#.utf8).write(to: work.appendingPathComponent("escaped.json"))
        // How agent code decodes each file's bytes (`b`, a Buffer).
        let cases: [(file: String, decode: String, value: String)] = [
            ("utf16.json", #"b.toString("utf16le")"#, Self.value),
            ("utf32.json", #"Array.from(b).filter((_, i) => i % 4 === 3).map((c) => String.fromCharCode(c)).join("")"#, Self.value),
            ("escaped.json", #"JSON.stringify(JSON.parse(b.toString("utf8")))"#, "4271"),
        ]
        for item in cases {
            let session = try #require(makeSession(ScriptedPageDriver(), cwd: work.path))
            defer { session.close() }
            let result = await run(session, """
            const fs = await import("node:fs");
            let loaded = true;
            try { secrets.load("./\(item.file)"); } catch (e) { loaded = false; console.log("refused: " + e.message); }
            const b = fs.readFileSync("./\(item.file)");
            console.log("loaded " + loaded);
            if (loaded) console.log((\(item.decode)).split("").join(" "));
            """)
            let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
            #expect(result?.error == nil, "\(item.file): \(result?.error ?? "")")
            #expect(output.contains("loaded "), "\(item.file): \(output)")
            #expect(!output.contains(spelled(item.value)), "\(item.file): a loaded value was read back unmasked: \(output)")
        }
    }

    private func currentCode() -> String {
        BrowserReplSecretStore.totp(key: BrowserReplSecretStore.base32Decode(Self.totpSeed) ?? Data(), time: Date().timeIntervalSince1970)
    }
}

/// A page driver whose app reports a secret another session typed into a
/// tab this session reaches (``BrowserReplTypedSecrets``).
private final class TypedSecretsPageDriver: BrowserReplDriver, @unchecked Sendable {
    private let page = ScriptedPageDriver()
    private let typed: BrowserReplSecretStore

    init(typed: BrowserReplSecretStore) {
        self.typed = typed
    }

    var capabilities: [String] { page.capabilities }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        await page.call(method: method, paramsJSON: paramsJSON)
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}

    func typedSecretRedaction() -> BrowserReplSecretStore? { typed }
}

/// A page driver that holds `tab.screenshot` until a secret is typed;
/// meanwhile page reads answer "capturing".
private final class HeldCaptureDriver: BrowserReplDriver, @unchecked Sendable {
    let page = ScriptedPageDriver()
    private let lock = NSLock()
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var capabilities: [String] { page.capabilities }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        switch method {
        case "tab.screenshot":
            page.pageValue = "capturing"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                    lock.unlock()
                }
            }
            return await page.call(method: method, paramsJSON: paramsJSON)
        case "input.insertText":
            let result = await page.call(method: method, paramsJSON: paramsJSON)
            if JSONSerialization.browserReplObject(paramsJSON)["secretName"] != nil { release() }
            return result
        default:
            return await page.call(method: method, paramsJSON: paramsJSON)
        }
    }

    private func release() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { releaseWaiters.removeAll() }
            return releaseWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}
}
