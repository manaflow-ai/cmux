import Foundation
import Testing

@testable import CmuxBrowser

/// The domain policy judges a fetch by its URL, so a caller header that
/// names another authority (`Host`, `:authority`) or reshapes the transport
/// (`Connection`, `Transfer-Encoding`, `Content-Length` and the like) could
/// reach a virtual host the policy blocks on the same server. Such a fetch
/// is refused before anything is sent, on its first URL and therefore on
/// every redirect hop, which reapplies the caller's headers.
@Suite("Browser REPL fetch transport headers", .serialized)
struct BrowserReplFetchTransportHeaderTests {
    private struct Outcome {
        let result: Result<String, BrowserReplDriverError>
        let requests: Int
        let receivedHosts: [String]
    }

    /// Fetches `path` on a local server the policy allows, with
    /// `headers`, while the policy blocks `blocked.example`.
    private func fetch(path: String, headers: [[String]]) async throws -> Outcome {
        let requests = BrowserReplResponseCounter()
        let hosts = BrowserReplReceivedHosts()
        let server = try BrowserReplTestHTTPServer { path, received, port in
            requests.increment()
            hosts.append(received["host"] ?? "")
            if path == "/redirect" { return (302, ["Location": "http://127.0.0.1:\(port)/landing"], Data()) }
            return (200, ["Content-Type": "text/plain"], Data("ok".utf8))
        }
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }
        fetcher.setBlockReason { url in
            URL(string: url)?.host == "blocked.example" ? "blocked.example is prohibited" : nil
        }
        let request: [String: Any] = [
            "url": "http://127.0.0.1:\(server.port)\(path)",
            "method": "GET",
            "headers": headers,
            "credentials": "omit",
        ]
        let result = await fetcher.fetch(requestJSON: JSONSerialization.browserReplString(request) ?? "{}")
        return Outcome(result: result, requests: requests.count, receivedHosts: hosts.values)
    }

    private func expectRefused(_ outcome: Outcome, naming name: String) {
        guard case .failure(let error) = outcome.result else {
            Issue.record("the fetch with \(name) was sent; the server saw Host \(outcome.receivedHosts)")
            return
        }
        #expect(error.code == "invalid", "\(error)")
        #expect(error.message.contains(name), "\(error.message)")
        #expect(outcome.requests == 0, "the server got \(outcome.requests) requests")
    }

    @Test("A fetch to an allowed URL with a Host header naming a blocked virtual host is refused before it is sent")
    func hostHeaderIsRefused() async throws {
        let outcome = try await fetch(path: "/", headers: [["Host", "blocked.example"]])
        expectRefused(outcome, naming: "Host")
    }

    @Test("A Host header is refused whatever its case and surrounding space")
    func hostHeaderCaseIsRefused() async throws {
        let outcome = try await fetch(path: "/", headers: [[" hOsT ", "blocked.example"]])
        expectRefused(outcome, naming: "hOsT")
    }

    @Test("A redirect hop never carries a caller Host header: the fetch is refused before its first request")
    func redirectHopDoesNotCarryHost() async throws {
        let outcome = try await fetch(path: "/redirect", headers: [["Accept", "text/plain"], ["Host", "blocked.example"]])
        expectRefused(outcome, naming: "Host")
        #expect(!outcome.receivedHosts.contains("blocked.example"), "\(outcome.receivedHosts)")
    }

    @Test("An HTTP/2 pseudo-header such as :authority is refused")
    func pseudoHeaderIsRefused() async throws {
        let outcome = try await fetch(path: "/", headers: [[":authority", "blocked.example"]])
        expectRefused(outcome, naming: ":authority")
    }

    @Test("Transport headers are refused", arguments: [
        "Connection", "Keep-Alive", "Proxy-Authorization", "Proxy-Authenticate", "Proxy-Connection",
        "Transfer-Encoding", "TE", "Trailer", "Upgrade", "Content-Length", "Expect",
    ])
    func transportHeaderIsRefused(name: String) async throws {
        let outcome = try await fetch(path: "/", headers: [[name, "x"]])
        expectRefused(outcome, naming: name)
    }

    @Test("A header name or value holding CR, LF or NUL is refused")
    func controlCharactersAreRefused() async throws {
        expectRefused(try await fetch(path: "/", headers: [["X-Note", "a\r\nHost: blocked.example"]]), naming: "X-Note")
        expectRefused(try await fetch(path: "/", headers: [["X-Note", "a\u{0}b"]]), naming: "X-Note")
        expectRefused(try await fetch(path: "/", headers: [["X-A\nHost", "blocked.example"]]), naming: "X-A")
    }

    @Test("Ordinary headers are still sent")
    func ordinaryHeadersAreSent() async throws {
        let outcome = try await fetch(path: "/redirect", headers: [["Accept", "text/plain"], ["X-Client-Ref", "r1"]])
        guard case .success = outcome.result else {
            Issue.record("fetch failed: \(outcome.result)")
            return
        }
        #expect(outcome.requests == 2)
    }
}

/// The `Host` header of each request a test server received.
final class BrowserReplReceivedHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []

    func append(_ host: String) { lock.withLock { hosts.append(host) } }
    var values: [String] { lock.withLock { hosts } }
}
