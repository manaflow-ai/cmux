import Foundation
import Testing

@testable import CmuxBrowser

/// A redirect to another origin must not carry the credentials the request
/// sent to the first one, as browsers drop `Authorization` there.
@Suite("Browser REPL fetch redirects", .serialized)
struct BrowserReplFetchRedirectTests {
    /// The request headers the landing server received, lowercased.
    private func landingHeaders(redirectingFrom path: String) async throws -> [String: String] {
        let landing = try BrowserReplTestHTTPServer { _, headers, _ in
            let body = (try? JSONSerialization.data(withJSONObject: headers)) ?? Data()
            return (200, ["Content-Type": "application/json"], body)
        }
        try await landing.start()
        defer { landing.stop() }
        let start = try BrowserReplTestHTTPServer { path, headers, port in
            switch path {
            case "/cross": return (302, ["Location": "http://127.0.0.1:\(landing.port)/landing"], Data())
            case "/same": return (302, ["Location": "http://127.0.0.1:\(port)/echo"], Data())
            default:
                let body = (try? JSONSerialization.data(withJSONObject: headers)) ?? Data()
                return (200, ["Content-Type": "application/json"], body)
            }
        }
        try await start.start()
        defer { start.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }

        let request: [String: Any] = [
            "url": "http://127.0.0.1:\(start.port)\(path)",
            "method": "GET",
            "headers": [
                ["Authorization", "Bearer s3cret"],
                ["Proxy-Authorization", "Basic cHJveHk="],
                ["X-Api-Key", "k3y"],
                ["X-Auth-Token", "t0ken"],
                ["Cookie", "sid=agent"],
                ["Accept", "application/json"],
            ],
            "credentials": "omit",
        ]
        let result = await fetcher.fetch(requestJSON: JSONSerialization.browserReplString(request) ?? "{}")
        guard case .success(let json) = result else {
            Issue.record("fetch failed: \(result)")
            return [:]
        }
        let response = JSONSerialization.browserReplObject(json)
        let body = Data(base64Encoded: response["bodyBase64"] as? String ?? "") ?? Data()
        return (try JSONSerialization.jsonObject(with: body) as? [String: String]) ?? [:]
    }

    @Test("A redirect to another origin drops Authorization, Proxy-Authorization, Cookie and credential-named headers")
    func crossOriginRedirectDropsCredentials() async throws {
        let headers = try await landingHeaders(redirectingFrom: "/cross")
        for name in ["authorization", "proxy-authorization", "cookie", "x-api-key", "x-auth-token"] {
            #expect(headers[name] == nil, "\(name) reached the other origin: \(headers)")
        }
        #expect(headers["accept"] == "application/json", "\(headers)")
    }

    /// Foundation itself drops `Authorization` on every redirect, so only
    /// the custom headers show that a same-origin hop keeps them.
    @Test("A redirect within the origin keeps the request's custom headers")
    func sameOriginRedirectKeepsHeaders() async throws {
        let headers = try await landingHeaders(redirectingFrom: "/same")
        #expect(headers["x-api-key"] == "k3y", "\(headers)")
        #expect(headers["x-auth-token"] == "t0ken", "\(headers)")
        #expect(headers["accept"] == "application/json", "\(headers)")
    }
}
