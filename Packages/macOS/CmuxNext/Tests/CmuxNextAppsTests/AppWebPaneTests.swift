import CmuxNextApps
import Foundation
import Testing

/// App web panes: a `cmux.pane/1` with `web` routes to a page served only from its own folder in
/// the app bundle, under a page host outside the reserved `cmux.` namespace.
struct AppWebPaneTests {
    private func manifest(_ pane: String) throws -> AppManifest {
        let text = #"{"id":"cmux/charts","manifestVersion":2,"implements":{"cmux.pane/1":"# + pane + "}}"
        return try #require(AppManifest(json: AppJSON.parse(text)))
    }

    @Test func aWebPaneRoutesToItsPage() throws {
        let app = try manifest(#"{"web":"web/index.html","title":{"en":"Charts"}}"#)
        guard case .web(let pane) = AppPaneRoute(app) else {
            Issue.record("a web pane did not route to its page")
            return
        }
        #expect(pane.entry == "web/index.html")
    }

    @Test func thePageIsServedOnlyFromItsFolderInTheBundle() {
        let bundle = URL(fileURLWithPath: "/apps/cmux/charts", isDirectory: true)
        let pane = { AppWebPane(implementation: AppImplementation(interface: AppImplementation.pane), entry: $0) }
        #expect(pane("web/index.html").root(in: bundle)?.path == "/apps/cmux/charts/web")
        #expect(pane("index.html").root(in: bundle)?.path == "/apps/cmux/charts")
        #expect(pane("../other/index.html").root(in: bundle) == nil)
        #expect(pane("/etc/index.html").root(in: bundle) == nil)
        #expect(pane("web/./index.html").root(in: bundle) == nil)
        #expect(pane("web/page.html").root(in: bundle) == nil)
    }

    @Test func thePageHostIsReverseDNSOutsideTheCmuxNamespace() {
        #expect(AppWebPane.pageHost(appID: "cmux/codemirror") == "codemirror.cmux.apps")
        #expect(AppWebPane.pageHost(appID: "local/customize") == "customize.local.apps")
        #expect(AppWebPane.pageHost(appID: "cmux") == nil)
        #expect(AppWebPane.pageHost(appID: "a/b/c") == nil)
        #expect(AppWebPane.pageHost(appID: "Evil/x.y") == nil)
    }
}
