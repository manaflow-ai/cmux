@testable import CmuxNextPages
import Foundation
import Testing

/// The agent pane's live dev server on the page host: with the pane's own scheme
/// handler gone, a `web-dev.json` server (``WebDevOverride``) serves `cmux-page://cmux.agent/` the
/// way it served `cmux-agent://pane`: the document from the webviews server's `/agent-pane/`, every
/// module at its own path and query.
struct PageDevServerAgentPageTests {
    /// The agent page as the page host knows it (`PageDescriptor.agent` lives in CmuxNextAgentPane).
    private let agent = PageDescriptor(id: "cmux.agent", resource: "agent-pane", processGroup: .agent, namespaces: ["cmux.agent."])
    private let server = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1:4181/"}"#.utf8), home: URL(fileURLWithPath: "/")).server

    @Test func theDocumentIsTheServersAgentPanePage() throws {
        let server = try #require(server)
        for path in ["/", "/index.html"] {
            let url = try #require(URL(string: agent.origin + path))
            #expect(server.url(for: url, page: agent)?.absoluteString == "http://127.0.0.1:4181/agent-pane/")
        }
    }

    @Test func modulesKeepTheirPathAndQuery() throws {
        let server = try #require(server)
        let url = try #require(URL(string: agent.origin + "/node_modules/.vite/deps/react.js?v=abc123"))
        #expect(server.url(for: url, page: agent)?.absoluteString == "http://127.0.0.1:4181/node_modules/.vite/deps/react.js?v=abc123")
        let client = try #require(URL(string: agent.origin + "/@vite/client"))
        #expect(server.url(for: client, page: agent)?.absoluteString == "http://127.0.0.1:4181/@vite/client")
    }

    @Test func refusesOtherOriginsAndDotSegments() throws {
        let server = try #require(server)
        // `%2E%2E` decodes to `..` in the path, so it is refused too.
        for string in ["cmux-page://cmux.history/index.html", "cmux-agent://pane/index.html", agent.origin + "/src/../secret",
                       agent.origin + "/src/%2E%2E/secret"] {
            let url = try #require(URL(string: string))
            #expect(server.url(for: url, page: agent) == nil, "\(string)")
        }
    }

    /// An app page (not first-party) still never loads from the server.
    @Test func anAppPageIsNeverServed() throws {
        let server = try #require(server)
        let app = PageDescriptor(id: "com.example.app", resource: "app", processGroup: .solo, namespaces: ["com.example.app."])
        let url = try #require(URL(string: app.origin + "/"))
        #expect(server.url(for: url, page: app) == nil)
    }
}
