import Foundation
import Network
import Testing

@testable import CmuxBrowser

/// A driver that answers the runtime's page-agent calls for one page with
/// one text field, and records what it receives. Like the app's driver, it
/// types a secret (`input.insertText` with `secretDomains`) only when the
/// page's origin matches.
final class ScriptedPageDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(method: String, params: [String: Any])] = []
    /// What a page-world evaluation returns (a read of the page).
    var pageValue: Any = "page"
    var cookies: [[String: Any]] = []
    private var url = "https://example.com/login"
    private var fillCalls = 0
    /// `fill` fails as detached once and the page moves to this URL first.
    var navigateOnFirstFill: String?
    private(set) var typedInto: [(url: String, text: String)] = []
    /// Secret inserts refused because the page's origin did not match.
    private(set) var refusedSecrets: [String] = []

    var capabilities: [String] { [] }

    var currentURL: String { lock.withLock { url } }

    func methods() -> [String] { lock.withLock { calls.map(\.method) } }

    func params(_ method: String) -> [[String: Any]] {
        lock.withLock { calls.filter { $0.method == method }.map(\.params) }
    }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        let params = JSONSerialization.browserReplObject(paramsJSON)
        lock.withLock { calls.append((method, params)) }
        func json(_ value: Any) -> Result<String, BrowserReplDriverError> {
            .success(JSONSerialization.browserReplString(value) ?? "null")
        }
        switch method {
        case "tabs.list":
            return json([["targetId": "t1", "title": "Login", "url": currentURL, "active": true]])
        case "tabs.open":
            return json(["targetId": "t1"])
        case "tab.info":
            return json(["url": currentURL, "title": "Login", "loadState": "load", "viewport": ["width": 1280, "height": 800], "deviceScaleFactor": 2])
        case "frames.list":
            return json([["frameId": "main", "parentFrameId": NSNull(), "url": currentURL, "name": "", "crossOrigin": false]])
        case "tab.navigate":
            let target = params["url"] as? String ?? ""
            lock.withLock { url = target }
            return json(["url": target, "status": 200])
        case "cookies.get":
            return json(cookies)
        case "tab.screenshot":
            return json(["base64": "", "width": 1, "height": 1])
        case "input.insertText":
            let text = params["text"] as? String ?? ""
            if let domains = params["secretDomains"] as? [[String: Any]] {
                // Hosts only: enough for these tests' plain domain patterns.
                let hosts = domains.compactMap { $0["host"] as? String }
                guard let page = URL(string: currentURL), page.scheme == "https", let host = page.host, hosts.contains(host) else {
                    let refusedAt = currentURL
                    lock.withLock { refusedSecrets.append(refusedAt) }
                    return .failure(BrowserReplDriverError(code: "invalid", message: "secret \"\(params["secretName"] as? String ?? "")\" may not be typed into \(currentURL)"))
                }
            }
            let typedAt = currentURL
            lock.withLock { typedInto.append((typedAt, text)) }
            return json(NSNull())
        case "frame.evaluate":
            let args = params["args"] as? [Any] ?? []
            if params["world"] as? String == "page" { return json(pageValue) }
            let source = params["source"] as? String ?? ""
            if source.contains("location.href") { return json(currentURL) }
            switch args.first as? String {
            case "splitFrames": return json([args.dropFirst().first ?? ""])
            case "queryAll": return json(["h1"])
            case "checkStates": return json("done")
            case "fill":
                let first: Bool = lock.withLock {
                    fillCalls += 1
                    return fillCalls == 1
                }
                if first, let next = navigateOnFirstFill {
                    lock.withLock { url = next }
                    return json("error:notconnected")
                }
                return json("needsinput")
            default:
                return json(NSNull())
            }
        default:
            return json(NSNull())
        }
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {}
    func detach() {}

}

/// Serves canned HTTP/1.1 responses on 127.0.0.1 for fetch tests.
final class BrowserReplTestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cmux.browser-repl.test-http")
    private let respond: @Sendable (_ path: String, _ headers: [String: String], _ port: UInt16) -> (status: Int, headers: [String: String], body: Data)
    private(set) var port: UInt16 = 0

    init(respond: @escaping @Sendable (_ path: String, _ headers: [String: String], _ port: UInt16) -> (status: Int, headers: [String: String], body: Data)) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = BrowserReplOnceBox<Void>()
            box.set(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = self?.listener.port?.rawValue ?? 0
                    box.resume(())
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !done { self.receive(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let path = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let response = self.respond(path, headers, self.port)
            var text = "HTTP/1.1 \(response.status) X\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
            for (name, value) in response.headers { text += "\(name): \(value)\r\n" }
            var out = Data((text + "\r\n").utf8)
            out.append(response.body)
            connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite("Browser REPL native boundary", .serialized)
struct BrowserReplBoundaryTests {
    private static let value = "v4lue-xyz-7731"

    private func makeSession(_ driver: ScriptedPageDriver) throws -> BrowserReplSession {
        BrowserReplSession(
            id: "boundary-\(UUID().uuidString)",
            cwd: browserReplTestWorkingDirectory,
            bundle: try browserReplRepositoryBundle(),
            driver: driver
        )
    }

    private func run(_ session: BrowserReplSession, _ code: String) async -> BrowserReplEvalResult? {
        await browserReplWithDeadline(seconds: 60) { await session.evaluate(code: code, timeout: .seconds(30)) }
    }

    private func spelled(_ text: String) -> String {
        text.map(String.init).joined(separator: " ")
    }

    @Test("Agent code cannot reach the native host")
    func nativeHostIsHidden() async throws {
        let session = try makeSession(ScriptedPageDriver())
        defer { session.close() }
        let result = await run(session, "typeof __cmuxNative")
        #expect(result?.error == nil)
        #expect(result?.lines.map(\.text) == ["undefined"])
    }

    @Test("A secret's value never reaches JavaScript, even through runtime internals")
    func secretValueStaysNative() async throws {
        let session = try makeSession(ScriptedPageDriver())
        defer { session.close() }
        let result = await run(session, """
        secrets.set("k", "\(Self.value)", { domains: ["example.com"] });
        const tools = page._session.agentTools;
        let leaked = null;
        try {
          leaked = await tools.resolveSecret(secret("k"), { _call: async () => "https://example.com/" }, "x");
        } catch (e) {}
        console.log("leaked:", String(leaked).split("").join(" "));
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(result != nil)
        #expect(!output.contains(spelled(Self.value)), "\(output)")
    }

    @Test("Turning off the runtime's hooks does not unmask a secret read from the page")
    func redactionIsNative() async throws {
        let driver = ScriptedPageDriver()
        driver.pageValue = ["field": Self.value]
        let session = try makeSession(driver)
        defer { session.close() }
        let result = await run(session, """
        secrets.set("k", "\(Self.value)", { domains: ["example.com"] });
        try { page._session.agentTools = null; } catch (e) {}
        console.log(JSON.stringify(await page.evaluate(() => 1)));
        """)
        let output = result?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(!output.contains(Self.value), "\(output)")
        #expect(output.contains("<secret:k>"), "\(output)")
    }

    @Test("A locked domain policy holds when agent code switches off the runtime's checks")
    func lockedPolicyIsNative() async throws {
        let driver = ScriptedPageDriver()
        let session = try makeSession(driver)
        defer { session.close() }
        _ = await run(session, """
        session.allowedDomains(["example.com"], { lock: true });
        try { page._session.agentTools = null; } catch (e) {}
        await page.goto("https://evil.test/").catch(() => {});
        await page._session.driver.call("tabs.open", { url: "https://evil.test/" }).catch(() => {});
        await page._session.driver.call("session.configure", { contentRules: [] }).catch(() => {});
        """)
        let navigations = (driver.params("tab.navigate") + driver.params("tabs.open")).compactMap { $0["url"] as? String }
        #expect(!navigations.contains { $0.contains("evil.test") }, "\(navigations)")
        let cleared = driver.params("session.configure").contains { ($0["contentRules"] as? [Any])?.isEmpty == true }
        #expect(!cleared)
    }

    @Test("A host with a trailing dot or in upper case is still a prohibited host")
    func trailingDotHosts() async throws {
        let driver = ScriptedPageDriver()
        let session = try makeSession(driver)
        defer { session.close() }
        _ = await run(session, """
        session.prohibitedDomains(["example.org"]);
        await page.goto("https://example.org./").catch(() => {});
        await page.goto("https://EXAMPLE.org../x").catch(() => {});
        """)
        let navigations = driver.params("tab.navigate").compactMap { $0["url"] as? String }
        #expect(!navigations.contains { $0.lowercased().contains("example.org") }, "\(navigations)")
    }

    @Test("A secret fill that retries after the page moved to another origin is refused")
    func secretFillRetryIsRechecked() async throws {
        let driver = ScriptedPageDriver()
        driver.navigateOnFirstFill = "https://evil.test/login"
        let session = try makeSession(driver)
        defer { session.close() }
        _ = await run(session, """
        secrets.set("k", "\(Self.value)", { domains: ["example.com"] });
        await page.goto("https://example.com/login");
        await page.locator("#f").fill(secret("k"), { timeout: 2000 }).catch((e) => console.log(e.message));
        """)
        let leaked = driver.typedInto.filter { $0.url.contains("evil.test") }
        #expect(leaked.isEmpty, "\(leaked)")
        // The retry reached the driver with the secret's domains and was refused there.
        #expect(driver.refusedSecrets.contains { $0.contains("evil.test") }, "\(driver.methods())")
    }

    @Test("Masking a capture never sends a secret's value to a page script world")
    func captureMaskingStaysOutOfPages() async throws {
        let driver = ScriptedPageDriver()
        let session = try makeSession(driver)
        defer { session.close() }
        _ = await run(session, """
        secrets.set("k", "\(Self.value)", { domains: ["example.com"] });
        await page.goto("https://example.com/login");
        await page.screenshot().catch(() => {});
        """)
        let evaluations = driver.params("frame.evaluate").map { JSONSerialization.browserReplString($0) ?? "" }
        #expect(!evaluations.contains { $0.contains(Self.value) })
    }

    @Test("fetch checks every redirect hop, honors credentials and caps the body")
    func fetchHopsCredentialsAndCap() async throws {
        let big = 65 << 20
        let server = try BrowserReplTestHTTPServer { path, headers, port in
            switch path {
            case "/redirect":
                return (302, ["Location": "http://localhost:\(port)/target"], Data())
            case "/target":
                return (200, ["Content-Type": "text/plain"], Data("target".utf8))
            case "/echo":
                return (200, ["Content-Type": "text/plain"], Data("cookie=\(headers["cookie"] ?? "")".utf8))
            case "/big":
                return (200, ["Content-Type": "application/octet-stream"], Data(count: big))
            default:
                return (404, [:], Data())
            }
        }
        try await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        let driver = ScriptedPageDriver()
        driver.cookies = [["name": "sid", "value": "abc", "domain": "127.0.0.1", "path": "/"]]
        let session = try makeSession(driver)
        defer { session.close() }

        let redirect = await run(session, """
        session.allowedDomains(["127.0.0.1"]);
        try { page._session.agentTools = null; } catch (e) {}
        console.log(await fetch("\(base)/redirect").then((r) => r.text(), (e) => "error: " + e.message));
        session.allowedDomains(null);
        """)
        let redirectText = redirect?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(redirectText.contains("is blocked"), "\(redirectText)")
        #expect(redirectText != "target", "\(redirectText)")

        let omit = await run(session, """
        console.log(await fetch("\(base)/echo", { credentials: "omit" }).then((r) => r.text(), (e) => "error: " + e.message));
        """)
        #expect(omit?.lines.map(\.text) == ["cookie="])

        let capped = await run(session, """
        console.log(await fetch("\(base)/big").then(async (r) => "bytes " + (await r.arrayBuffer()).byteLength, (e) => "error: " + e.message));
        """)
        let cappedText = capped?.lines.map(\.text).joined(separator: "\n") ?? ""
        #expect(cappedText.contains("larger than 64 MiB"), "\(cappedText)")
    }
}
