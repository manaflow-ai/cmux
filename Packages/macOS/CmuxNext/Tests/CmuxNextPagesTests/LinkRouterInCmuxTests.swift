import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A terminal opens its cmux-browser links beside itself (`inCmux`, https://github.com/manaflow-ai/cmux/issues/22271);
/// the focused-pane tab (`openInCmux`) stays the fallback.
@MainActor
struct LinkRouterInCmuxTests {
    private func makeRouter(opened: @escaping (URL) -> Void) -> LinkRouter {
        let router = LinkRouter()
        router.routing = { LinkRouting(opensInCmuxBrowser: true, embeddedHosts: [], externalRules: []) }
        router.openInCmux = { url, _ in opened(url) }
        return router
    }

    @Test func aCmuxLinkOpensWhereTheCallerPutsIt() throws {
        let url = try #require(URL(string: "https://example.com/docs"))
        var focusedPane: [URL] = [], beside: [URL] = []
        let router = makeRouter { focusedPane.append($0) }

        let target = router.open(url) { beside.append($0); return true }

        #expect(target == .cmuxBrowser)
        #expect(beside == [url])
        #expect(focusedPane.isEmpty)
    }

    @Test func aRefusedPlacementFallsBackToTheFocusedPane() throws {
        let url = try #require(URL(string: "https://example.com/docs"))
        var focusedPane: [URL] = []
        let router = makeRouter { focusedPane.append($0) }

        #expect(router.open(url) { _ in false } == .cmuxBrowser)
        #expect(focusedPane == [url])
    }
}
