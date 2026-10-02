import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The Debug Settings switch between the two agent pane prototypes.
@Suite struct AgentPanePrototypeTests {
    @Test func everyPrototypeShipsItsOwnPage() throws {
        let current = try #require(AgentPanePrototype.current.bundledPage)
        let port = try #require(AgentPanePrototype.port.bundledPage)
        #expect(current != port)
        #expect(current == AgentPaneView.bundledPage)
        // Both pages are self-contained and speak the same host contract.
        for page in [current, port] {
            let html = try String(contentsOf: page, encoding: .utf8)
            #expect(html.contains("connect-src ws://127.0.0.1:*"))
            #expect(html.contains("cmuxAcpmuxActions"))
        }
    }

    @Test func releaseDefaultIsTheCurrentPane() {
        #expect(AgentPaneTunables.prototype.defaultValue == .current)
        #expect(AgentPanePrototype(tunableValue: .choice("port")) == .port)
        #expect(AgentPanePrototype(tunableValue: .choice("missing")) == nil)
    }

    @Test func thePortLoadsFromTheBundleAndIsTrusted() throws {
        let port = try #require(AgentPanePrototype.port.bundledPage)
        let source = try #require(AgentPaneSource.resolve(environment: [:], bundledPage: port, allowsDevServer: true))
        #expect(source == .bundled(port))
        #expect(source.isTrusted(port))
        #expect(!source.isTrusted(AgentPanePrototype.current.bundledPage))
    }
}
