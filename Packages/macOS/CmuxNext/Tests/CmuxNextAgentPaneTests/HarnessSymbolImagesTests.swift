import Foundation
import Testing
@testable import CmuxNextAgentPane

/// User 12922: a custom harness's SF Symbol icon shows on the pages as the host's template image.
/// The page asks `harness.symbol {name}`; only a symbol name decodes, a drawable one answers a PNG
/// `data:` URL, and a name this Mac does not draw answers nothing (the page keeps the monogram).
@MainActor
struct HarnessSymbolImagesTests {
    private func request(_ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "harness.symbol", "params": params])
    }

    @Test func onlyASymbolNameDecodes() {
        if case .harnessSymbol("hammer.fill") = request(["name": "hammer.fill"]) {} else { Issue.record("hammer.fill") }
        for params: [String: Any] in [[:], ["name": ""], ["name": "Hammer"], ["name": "../x"], ["name": "a..b"], ["name": 7]] {
            if case .unsupported = request(params) {} else { Issue.record("\(params)") }
        }
    }

    @Test func aDrawableSymbolAnswersATemplatePNG() async throws {
        let model = AgentPaneModel(host: NoHost())
        let value = await model.respond(to: .harnessSymbol("hammer.fill"))["value"] as? [String: Any]
        let src = try #require(value?["src"] as? String)
        #expect(src.hasPrefix("data:image/png;base64,"))
        let png = try #require(Data(base64Encoded: String(src.dropFirst("data:image/png;base64,".count))))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let missing = await model.respond(to: .harnessSymbol("no.such.symbol.cmux"))["value"] as? [String: Any]
        #expect(missing?["src"] == nil)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
