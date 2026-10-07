import Foundation
import Network
import Testing
import WebKit

@testable import CmuxBrowser

/// `session.blockIPAddresses` reaches subresources through the content
/// rules, whose expressions match the URL WebKit loads. The policy reads
/// every numeric IPv4 spelling (`0x7f.1`, `2130706433`, `0177.0.0.1`) as
/// an IP address; these tests prove, with a real web view and a loopback
/// server, that no such spelling of 127.0.0.1 or ::1 reaches the network
/// while the rules are installed.
@MainActor
@Suite(.serialized)
struct BrowserReplContentRuleIPTests {
    /// Spellings of 127.0.0.1 that WHATWG URL parsers accept.
    static let ipv4Spellings = [
        "127.0.0.1",
        "127.0.0.1.",
        "127.1",
        "127.0.1",
        "0x7f.1",
        "0x7f.0.0.1",
        "0X7F.0X0.0X0.0X1",
        "0x7f000001",
        "2130706433",
        "0177.0.0.1",
        "0177.1",
        "017700000001",
        "127.000.000.001",
        "%31%32%37.0.0.1",
        "１２７.０.０.１",
    ]

    /// Spellings of ::1.
    static let ipv6Spellings = [
        "[::1]",
        "[0:0:0:0:0:0:0:1]",
        "[0000:0000:0000:0000:0000:0000:0000:0001]",
    ]

    @Test("No IPv4 spelling of a loopback address loads under blockIPAddresses")
    func numericIPv4SpellingsAreBlocked() async throws {
        let server = try await LoopbackServer.start(host: "127.0.0.1")
        defer { server.stop() }
        let unblocked = try await Self.page(blockingIPs: false)
        // The server answers a page with no rules: a failure below is the rules'.
        #expect(try await Self.fetch("http://127.0.0.1:\(server.port)/control", in: unblocked) == "loaded")
        #expect(server.paths.contains("/control"))

        let page = try await Self.page(blockingIPs: true)
        for (index, host) in Self.ipv4Spellings.enumerated() {
            let path = "/v4-\(index)"
            let result = try await Self.fetch("http://\(host):\(server.port)\(path)", in: page)
            #expect(result == "failed", "http://\(host)/ loaded under blockIPAddresses")
            #expect(!server.paths.contains(path), "http://\(host)/ reached the server under blockIPAddresses")
        }
    }

    @Test("No IPv6 spelling of a loopback address loads under blockIPAddresses")
    func ipv6SpellingsAreBlocked() async throws {
        let server = try await LoopbackServer.start(host: "::1")
        defer { server.stop() }
        let unblocked = try await Self.page(blockingIPs: false)
        #expect(try await Self.fetch("http://[::1]:\(server.port)/control", in: unblocked) == "loaded")
        #expect(server.paths.contains("/control"))

        let page = try await Self.page(blockingIPs: true)
        for (index, host) in Self.ipv6Spellings.enumerated() {
            let path = "/v6-\(index)"
            let result = try await Self.fetch("http://\(host):\(server.port)\(path)", in: page)
            #expect(result == "failed", "http://\(host)/ loaded under blockIPAddresses")
            #expect(!server.paths.contains(path), "http://\(host)/ reached the server under blockIPAddresses")
        }
    }

    @Test("The policy itself reads each spelling as an IP address")
    func thePolicyBlocksEachSpelling() {
        var policy = BrowserReplDomainPolicy()
        policy.blockIPAddresses = true
        for host in Self.ipv4Spellings + Self.ipv6Spellings {
            #expect(policy.blockReason("http://\(host):8080/x") != nil, "\(host) is not blocked by the policy")
        }
    }

    /// r26 native#3: WebKit compiles a universal host pattern's IPv6
    /// filter and applies it: `prohibitedDomains: ["http://*"]` stops an
    /// IPv6 subresource and `allowedDomains: ["*"]` lets one load, while an
    /// IPv4 address written as IPv6, which the policy refuses natively,
    /// stays blocked under the allow list.
    @Test("A universal host pattern judges IPv6 subresources in WebKit as the policy does")
    func universalHostJudgesIPv6InWebKit() async throws {
        let v6 = try await LoopbackServer.start(host: "::1")
        defer { v6.stop() }
        let v4 = try await LoopbackServer.start(host: "127.0.0.1")
        defer { v4.stop() }

        var prohibiting = BrowserReplDomainPolicy()
        prohibiting.prohibited = [try BrowserReplDomainPattern.parse("http://*", title: "t")]
        let blocked = try await Self.page(prohibiting)
        #expect(try await Self.fetch("http://[::1]:\(v6.port)/prohibited", in: blocked) == "failed")
        #expect(!v6.paths.contains("/prohibited"), "an IPv6 subresource reached the server under prohibitedDomains http://*")

        var allowing = BrowserReplDomainPolicy()
        allowing.allowed = [try BrowserReplDomainPattern.parse("*", title: "t")]
        let open = try await Self.page(allowing)
        #expect(try await Self.fetch("http://[::1]:\(v6.port)/allowed", in: open) == "loaded")
        #expect(v6.paths.contains("/allowed"), "allowedDomains * blocked an IPv6 subresource the policy allows")
        #expect(allowing.blockReason("http://[::ffff:127.0.0.1]:\(v4.port)/mapped") != nil)
        #expect(try await Self.fetch("http://[::ffff:127.0.0.1]:\(v4.port)/mapped", in: open) == "failed")
        #expect(!v4.paths.contains("/mapped"), "an IPv4 address written as IPv6 loaded under allowedDomains *")
    }

    // MARK: - Support

    /// A page on a non-IP origin, with the policy's content rules when
    /// `blockingIPs`.
    private static func page(blockingIPs: Bool) async throws -> WKWebView {
        var policy = BrowserReplDomainPolicy()
        policy.blockIPAddresses = blockingIPs
        return try await page(blockingIPs ? policy : nil)
    }

    /// A page on a non-IP origin, with `policy`'s content rules when given.
    private static func page(_ policy: BrowserReplDomainPolicy?) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let policy {
            configuration.userContentController.add(try await compile(policy.contentRules))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "http://page.test/"))
        try await delegate.wait()
        webView.navigationDelegate = nil
        return webView
    }

    private static func compile(_ rules: [[String: Any]]) async throws -> WKContentRuleList {
        let data = try JSONSerialization.data(withJSONObject: rules)
        let json = String(decoding: data, as: UTF8.self)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ip-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try #require(WKContentRuleListStore(url: directory))
        let list = try await store.compileContentRuleList(forIdentifier: "ip-test", encodedContentRuleList: json)
        return try #require(list)
    }

    /// `loaded` when a no-cors fetch of `url` got a response, `failed` when
    /// it did not (the content rules or the network refused it).
    private static func fetch(_ url: String, in webView: WKWebView) async throws -> String? {
        try await webView.callAsyncJavaScript(
            """
            try {
              await fetch(url, { mode: "no-cors", cache: "no-store" });
              return "loaded";
            } catch (e) {
              return "failed";
            }
            """,
            arguments: ["url": url],
            in: nil,
            contentWorld: .page
        ) as? String
    }
}

/// Resumes once the web view's main frame finished loading.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func finish(_ value: Result<Void, any Error>) {
        guard result == nil else { return }
        result = value
        continuation?.resume(with: value)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }
}

/// An HTTP server on a loopback address that answers every request with an
/// empty 200 and records the request paths.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cmux.test.loopback-server")
    private let lock = NSLock()
    private var recorded: [String] = []
    private(set) var port: UInt16 = 0

    var paths: [String] { lock.withLock { recorded } }

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start(host: String) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        let server = LoopbackServer(listener: try NWListener(using: parameters))
        try await server.run()
        return server
    }

    private func run() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let started = BrowserReplOnceBox<Result<UInt16, any Error>>()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: started.resume(.success(listener.port?.rawValue ?? 0))
            case .failed(let error): started.resume(.failure(error))
            default: break
            }
        }
        listener.start(queue: queue)
        port = try await withCheckedContinuation { started.set($0) }.get()
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let requestLine = head.split(separator: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            if parts.count >= 2 { self.lock.withLock { self.recorded.append(String(parts[1])) } }
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
