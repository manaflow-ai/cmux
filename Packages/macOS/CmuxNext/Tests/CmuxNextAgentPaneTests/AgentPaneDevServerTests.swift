@testable import CmuxNextAgentPane
import CmuxNextPages
import Foundation
import Testing

/// The bundled pane's live dev server (``WebDevOverride``): which server URL each
/// `cmux-agent://pane` request goes to.
struct AgentPaneDevServerTests {
    /// The server a `web-dev.json` names (PageDevServer's initializer is the page module's own).
    private let server = WebDevOverride.parse(Data(#"{"server": "http://127.0.0.1:4181/"}"#.utf8), home: URL(fileURLWithPath: "/")).server

    @Test func theDocumentIsTheServersAgentPanePage() throws {
        let server = try #require(server)
        for path in ["/", "/index.html"] {
            let url = try #require(URL(string: "cmux-agent://pane" + path))
            #expect(AgentPaneSchemeHandler.devServerURL(for: url, server: server)?.absoluteString
                == "http://127.0.0.1:4181/agent-pane/index.html")
        }
    }

    @Test func modulesKeepTheirPathAndQuery() throws {
        let server = try #require(server)
        let url = try #require(URL(string: "cmux-agent://pane/node_modules/.vite/deps/react.js?v=abc123"))
        #expect(AgentPaneSchemeHandler.devServerURL(for: url, server: server)?.absoluteString
            == "http://127.0.0.1:4181/node_modules/.vite/deps/react.js?v=abc123")
        let client = try #require(URL(string: "cmux-agent://pane/@vite/client"))
        #expect(AgentPaneSchemeHandler.devServerURL(for: client, server: server)?.absoluteString == "http://127.0.0.1:4181/@vite/client")
    }

    @Test func refusesOtherOriginsAndDotSegments() throws {
        let server = try #require(server)
        // `%2E%2E` decodes to `..` in the path, so it is refused too.
        for string in ["cmux-agent://render/index.html", "https://pane/index.html", "cmux-agent://pane/src/../secret", "cmux-agent://pane/src/%2E%2E/secret"] {
            let url = try #require(URL(string: string))
            #expect(AgentPaneSchemeHandler.devServerURL(for: url, server: server) == nil)
        }
    }
}
