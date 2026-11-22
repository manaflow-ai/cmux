import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AgentPaneSourceTests {
    private let page = URL(fileURLWithPath: "/Applications/cmux.app/Contents/Resources/CmuxNext_CmuxNextAgentPane.bundle/agent-pane/index.html")

    private func resolve(_ override: String?, bundledPage: URL?, allowsDevServer: Bool = true) -> AgentPaneSource? {
        let environment = override.map { [AgentPaneSource.devURLVariable: $0] } ?? [:]
        return AgentPaneSource.resolve(environment: environment, bundledPage: bundledPage, allowsDevServer: allowsDevServer)
    }

    @Test func releaseIgnoresTheDevServerOverride() {
        #expect(resolve("http://127.0.0.1:4176/", bundledPage: page, allowsDevServer: false) == .bundled(page))
        #expect(resolve("http://127.0.0.1:4176/", bundledPage: nil, allowsDevServer: false) == nil)
    }

    @Test func debugUsesALoopbackDevServer() throws {
        let root = try #require(URL(string: "http://127.0.0.1:4176/"))
        #expect(resolve("http://127.0.0.1:4176/", bundledPage: page) == .devServer(root))
        #expect(resolve("http://127.0.0.1:4176", bundledPage: page) == .devServer(root))
        #expect(resolve(" http://127.0.0.1:4176/#row-4 ", bundledPage: page) == .devServer(root))
        let localhost = try #require(URL(string: "http://localhost:5173/"))
        #expect(resolve("HTTP://LOCALHOST:5173/", bundledPage: page) == .devServer(localhost))
        // The dev server needs no bundled page.
        #expect(resolve("http://127.0.0.1:4176/", bundledPage: nil) == .devServer(root))
    }

    @Test(arguments: [
        "https://127.0.0.1:4176/",
        "http://example.com:4176/",
        "http://192.168.1.20:4176/",
        "http://[::1]:4176/",
        "http://127.0.0.1/",
        "http://user:secret@127.0.0.1:4176/",
        "file:///tmp/index.html",
        "javascript:alert(1)",
        "127.0.0.1:4176",
        "not a url",
    ])
    func refusesNonLoopbackOrNonHTTPDevURLs(_ override: String) {
        #expect(resolve(override, bundledPage: page) == .bundled(page))
    }

    @Test func emptyOverrideKeepsTheBundledPage() {
        #expect(resolve("", bundledPage: page) == .bundled(page))
        #expect(resolve(nil, bundledPage: page) == .bundled(page))
    }

    @Test func missingBundleIsNil() {
        #expect(resolve(nil, bundledPage: nil) == nil)
        #expect(resolve("https://example.com/", bundledPage: nil) == nil)
    }

    @Test func onlyADevServerHasAnOriginForAcpmux() {
        #expect(resolve("http://127.0.0.1:4176/x", bundledPage: page)?.devServerOrigin == "http://127.0.0.1:4176")
        #expect(resolve(nil, bundledPage: page)?.devServerOrigin == nil)
        // Release never resolves the dev server, so it never passes an origin.
        #expect(resolve("http://127.0.0.1:4176/", bundledPage: page, allowsDevServer: false)?.devServerOrigin == nil)
    }
}
