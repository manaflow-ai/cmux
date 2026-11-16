@testable import CmuxNextBrowser
import Foundation
import Testing

/// Closed chats' garbage in the shared cmux-page renderer (`CEFPageRendererGC`): one notice per renderer that
/// hosts cmux pages, through one of its live pages; web pages and pages without a renderer get none.
@MainActor @Suite struct CEFPageRendererGCTests {
    typealias Page = CEFPageRendererGC.Page

    @Test func oneNoticePerCmuxPageRenderer() {
        let pages = [
            Page(browser: 12, isCmuxPage: true, rendererClients: [6]),
            Page(browser: 4, isCmuxPage: true, rendererClients: [6]),
            Page(browser: 9, isCmuxPage: true, rendererClients: [8, 6]),
            Page(browser: 2, isCmuxPage: false, rendererClients: [6]),
            Page(browser: 3, isCmuxPage: false, rendererClients: [11]),
            Page(browser: 7, isCmuxPage: true, rendererClients: []),
        ]
        #expect(CEFPageRendererGC.targets(pages) == [4, 9])
    }

    @Test func noCmuxPagesNoNotice() {
        #expect(CEFPageRendererGC.targets([Page(browser: 1, isCmuxPage: false, rendererClients: [3])]).isEmpty)
        #expect(CEFPageRendererGC.targets([]).isEmpty)
    }

    @Test func onlyTheCmuxPageSchemeCounts() {
        #expect(CEFPageRendererGC.isCmuxPage(URL(string: "cmux-page://cmux.agent/")))
        #expect(!CEFPageRendererGC.isCmuxPage(URL(string: "https://example.com/")))
        #expect(!CEFPageRendererGC.isCmuxPage(nil))
    }
}
