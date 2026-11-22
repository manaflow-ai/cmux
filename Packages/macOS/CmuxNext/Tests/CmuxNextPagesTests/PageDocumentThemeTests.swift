import CmuxNextDesign
@testable import CmuxNextPages
import Testing
import WebKit

/// A page's first frame has its theme (no-flicker F1): the view's theme is a document-start
/// script after the bootstrap, so it applies before the page's own code paints.
@MainActor
@Suite struct PageDocumentThemeTests {
    private func documentStart(_ page: PageWebView) -> [String] {
        page.webView.configuration.userContentController.userScripts
            .filter { $0.injectionTime == .atDocumentStart }.map(\.source)
    }

    @Test func aPageGetsItsThemeAtDocumentStart() throws {
        let page = try #require(PageWebView(pooledHost: .settings))
        let scripts = documentStart(page)
        let bootstrap = try #require(scripts.firstIndex(of: WebTheme.bootstrapScript))
        let theme = try #require(scripts.firstIndex(of: page.currentTheme().applyScript))
        #expect(bootstrap < theme)
    }

    @Test func aRetargetedHostGetsItsThemeAgain() throws {
        let page = try #require(PageWebView(pooledHost: .settings))
        #expect(page.retarget(descriptor: .history, routes: []))
        let scripts = documentStart(page)
        let bootstrap = try #require(scripts.firstIndex(of: WebTheme.bootstrapScript))
        let theme = try #require(scripts.firstIndex(of: page.currentTheme().applyScript))
        #expect(bootstrap < theme)
        #expect(scripts.filter { $0 == page.currentTheme().applyScript }.count == 1)
    }
}
