@testable import CmuxNextPages
import Foundation
import Testing

/// `CMUX_NEXT_PAGES_DEV_URL`: Debug and tagged builds serve every React page from one loopback
/// Vite server (`bun run dev:pages`) under the page's own `cmux-page://` origin, so edits hot
/// reload while the page keeps its host bridge. Release builds ignore the variable.
@MainActor
@Suite struct PageDevServerTests {
    static let environment = [PageDevServer.variable: "http://127.0.0.1:4180/"]

    @Test func releaseBuildsIgnoreTheVariable() {
        #expect(PageDevServer.resolve(environment: Self.environment, allowsDevServer: false) == nil)
        #expect(PageDevServer.resolve(environment: Self.environment, allowsDevServer: true)?.root.absoluteString
            == "http://127.0.0.1:4180/")
    }

    /// The agent pane override's rules: plain http on loopback, an explicit port, no credentials.
    @Test func onlyALoopbackHTTPServerIsAccepted() {
        let refused = [
            "https://127.0.0.1:4180/", "http://example.com:4180/", "http://10.0.0.2:4180/", "http://127.0.0.1/",
            "http://user:pw@127.0.0.1:4180/", "file:///tmp/pages", "", "127.0.0.1:4180",
        ]
        for value in refused {
            #expect(PageDevServer.resolve(environment: [PageDevServer.variable: value], allowsDevServer: true) == nil, "\(value)")
        }
        let accepted = PageDevServer.resolve(environment: [PageDevServer.variable: " http://LocalHost:4180#x "], allowsDevServer: true)
        #expect(accepted?.root.absoluteString == "http://localhost:4180/")
    }

    @Test func eachPageMapsToItsDevPath() throws {
        let dev = try #require(PageDevServer.resolve(environment: Self.environment, allowsDevServer: true))
        func mapped(_ page: PageDescriptor, _ path: String) -> String? {
            dev.url(for: URL(string: "\(page.origin)\(path)")!, page: page)?.absoluteString
        }
        #expect(mapped(.history, "/") == "http://127.0.0.1:4180/history/")
        #expect(mapped(.settings, "/index.html") == "http://127.0.0.1:4180/settings/")
        #expect(mapped(.diff, "/") == "http://127.0.0.1:4180/diff-page.html")
        #expect(mapped(.editor, "/editor-page.html") == "http://127.0.0.1:4180/editor-page.html")
        // Modules, the HMR client and dependencies keep their path and query.
        #expect(mapped(.history, "/src/pages/history/main.tsx?t=1") == "http://127.0.0.1:4180/src/pages/history/main.tsx?t=1")
        #expect(mapped(.markdown, "/@vite/client") == "http://127.0.0.1:4180/@vite/client")
        // A dynamic prefix stays with the page instance, another origin is not the page's.
        #expect(mapped(.settings, "/backdrop/1.png") == nil)
        #expect(mapped(.diff, "/__patch/abc/x") == nil)
        #expect(dev.url(for: URL(string: "cmux-page://cmux.apps/")!, page: .history) == nil)
        // Only the listed first-party pages: an app page or the agent pane (its own override) is never proxied.
        let app = PageDescriptor(id: "com.acme.notes", resource: "notes", namespaces: [])
        #expect(dev.url(for: URL(string: "cmux-page://com.acme.notes/")!, page: app) == nil)
        let agent = PageDescriptor(id: "cmux.agent", resource: "agent-pane", namespaces: [])
        #expect(dev.url(for: URL(string: "cmux-page://cmux.agent/")!, page: agent) == nil)
    }

    /// The Vite client opens its HMR socket to the server; the page's own sources stay.
    @Test func theDevPolicyAddsTheServerConnection() throws {
        let dev = try #require(PageDevServer.resolve(environment: Self.environment, allowsDevServer: true))
        #expect(dev.csp(for: .history).connect == ["ws://127.0.0.1:4180", "http://127.0.0.1:4180"])
        #expect(dev.csp(for: .diff).connect == ["cmux-page://cmux.diff", "ws://127.0.0.1:4180", "http://127.0.0.1:4180"])
        #expect(dev.csp(for: .diff).script == ["'wasm-unsafe-eval'"])
    }

    @Test func theSchemeHandlerServesThePageFromTheDevServer() async throws {
        let dev = try #require(PageDevServer.resolve(environment: Self.environment, allowsDevServer: true))
        let root = try #require(PageSchemeHandler.bundledRoot(for: .history))
        let handler = PageSchemeHandler(page: .history, root: root, devServer: dev)
        let requested = RequestLog()
        handler.fetchDevServer = { url in
            await requested.add(url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/javascript"])!
            return (Data("export {}".utf8), response)
        }
        let reply = try #require(await handler.reply(to: URL(string: "cmux-page://cmux.history/src/pages/history/main.tsx")!))
        #expect(await requested.urls == ["http://127.0.0.1:4180/src/pages/history/main.tsx"])
        #expect(reply.response.statusCode == 200)
        #expect(reply.response.value(forHTTPHeaderField: "Content-Type") == "text/javascript")
        #expect(reply.response.value(forHTTPHeaderField: "Content-Security-Policy") == dev.csp(for: .history).header)
        #expect(String(decoding: reply.body, as: UTF8.self) == "export {}")

        // Without the server the bundled page answers, as in Release.
        let bundled = PageSchemeHandler(page: .history, root: root, devServer: nil)
        let page = try #require(await bundled.reply(to: URL(string: "cmux-page://cmux.history/")!))
        #expect(page.response.value(forHTTPHeaderField: "Content-Security-Policy") == PageCSP.strict.header)
        #expect(String(decoding: page.body, as: UTF8.self).contains("data-cmux-page=\"history\""))
    }

    /// A redirect off the dev server's origin is not served under the page's origin.
    @Test func aReplyFromAnotherOriginIsRefused() async throws {
        let dev = try #require(PageDevServer.resolve(environment: Self.environment, allowsDevServer: true))
        let root = try #require(PageSchemeHandler.bundledRoot(for: .history))
        let handler = PageSchemeHandler(page: .history, root: root, devServer: dev)
        handler.fetchDevServer = { _ in
            let elsewhere = URL(string: "http://example.com/x.js")!
            return (Data(), HTTPURLResponse(url: elsewhere, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await handler.reply(to: URL(string: "cmux-page://cmux.history/x.js")!) == nil)
    }
}

private actor RequestLog {
    var urls: [String] = []
    func add(_ url: URL) { urls.append(url.absoluteString) }
}
