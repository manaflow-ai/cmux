import AppKit
@testable import CmuxNextAgentPane
import CmuxNextApps
@testable import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextApp

/// An app's pane tab is the React app pane page (`cmux.app-scene`), not the AppKit scene host: the
/// page names the app in its route, reaches only the panels namespace and its bundle images, and
/// closes with its tab (which ends its mount through ``AppsPanelsPageProvider/pageDidClose()``).
@MainActor @Suite struct AppPanePageTests {
    /// A scratch root for the page's document (the test bundle has no built pages; the first
    /// registration per process wins).
    private static let root: URL? = {
        let root = FileManager.default.temporaryDirectory.appending(path: "cn-app-scene-root-\(UUID().uuidString.prefix(8))")
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil,
              (try? Data("<html><body></body></html>".utf8).write(to: root.appending(path: "index.html"))) != nil else { return nil }
        return root
    }()

    @Test func theDescriptorAdmitsOnlyThePanelOpsAndServesBundleImages() {
        let page = PageDescriptor.appScene
        #expect(page.id == "cmux.app-scene")
        #expect(page.resource == "app-scene")
        #expect(page.admits("cmux.apps.panels.mount"))
        #expect(page.admits("cmux.apps.panels.scene"))
        #expect(!page.admits("cmux.apps.install"), "the pane page gets the panel ops only")
        #expect(!page.admits(PageNativeOp.actionRun))
        #expect(page.dynamicPrefixes == [AppsPanelsPageProvider.bundlePrefix, AppsPanelsPageProvider.symbolPrefix])
        #expect(!page.acceptsFirstMouse)
        #expect(FirstPartyPageSchemes.descriptors.contains(page))
    }

    @Test func theRouteNamesTheAppQueryEncoded() {
        #expect(AppScenePage.route(app: "samples/github-prs") == "#/?app=samples/github-prs")
        #expect(AppScenePage.route(app: "local/my app") == "#/?app=local/my%20app")
    }

    @Test func aPaneTabIsTheAppScenePageAndClosesWithItsTab() throws {
        let root = try #require(Self.root, "no scratch page root")
        PageID.registerBundledRoot(root, for: PageDescriptor.appScene.id)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let provider = AppPanePage(appID: "samples/github-prs", apps: services.apps)
        let view = provider.makeView(for: "tab-1", in: nil)
        let page = try #require(view as? PageWebView, "the app pane did not open as its React page")
        #expect(page.pageID == PageDescriptor.appScene.id)
        #expect(page.route == "#/?app=samples/github-prs")
        #expect(!(view is AppSceneHostingView), "the pane no longer draws through the AppKit scene host")
        #expect(!page.isClosed)
        provider.tabClosed("tab-1")
        #expect(page.isClosed, "closing the tab closes its page, which ends its mount")
        provider.tabClosed("tab-1") // a second close is a no-op
    }
}
