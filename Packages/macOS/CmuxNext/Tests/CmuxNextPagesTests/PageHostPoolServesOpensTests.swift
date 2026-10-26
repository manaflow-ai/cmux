import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Testing

/// Whether the page host pool's WebKit spare could serve any open (``PageHostPool/servesOpens(hosting:)``,
/// p13-webui-056): the decision that keeps a WebKit WebContent process out of Home while Settings, History and
/// Cloud show in Chromium. It must say what the pool's claim decides, page by page.
@MainActor @Suite(.serialized) struct PageHostPoolServesOpensTests {
    /// A Chromium page maker whose engine state a test sets; it makes no page.
    @MainActor private final class SetChromium: PageChromiumHosting {
        var preference: BrowserDefaultEngine = .chromium
        var isAvailable = true
        /// The ids of the pages Chromium's scheme does not serve.
        var unserved: Set<String> = []
        let work = BackgroundWork(cpuWidth: 1, label: "test.pool-serves-opens")
        let dialogs = CmuxDialogCenter(host: CmuxDialogHeadlessHost())

        struct NoPages: Error {}

        func serves(_ page: PageDescriptor) -> Bool { !unserved.contains(page.id) }
        func makePage(_ page: PageDescriptor, chatOpen: ChatOpenStages?, window: PageChromiumWindow?) async throws
            -> any PageChromiumPage { throw NoPages() }
        func supervisorOutcome(then answer: @escaping @MainActor @Sendable (PageChromiumSupervisorOutcome) -> Void) {
            answer(.gaveUp)
        }
    }

    /// Asserts `servesOpens` gives `expected` and agrees with claim's engine decision over the pooled pages.
    private func expectServes(_ expected: Bool, hosting: (any PageChromiumHosting)?, _ comment: Comment,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let memory = PageTestMemory()
        let pool = PageHostPool(memory: memory.coordinator, activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        let claimTakesWebKit = PageServedHosts.pooledDescriptors.contains { page in
            PageWebView.engineDecision(for: page, options: pool.options, hosting: hosting).engine == .webKit
        }
        let serves = pool.servesOpens(hosting: hosting)
        #expect(serves == expected, comment, sourceLocation: sourceLocation)
        #expect(serves == claimTakesWebKit, "servesOpens drifted from claim's engine decision", sourceLocation: sourceLocation)
    }

    @Test func noSpareServesWhileChromiumShowsEveryPooledPage() {
        #expect(PageServedHosts.pooledDescriptors.map(\.id) == [PageDescriptor.settings.id, PageDescriptor.history.id,
                                                                  PageDescriptor.cloud.id])
        expectServes(false, hosting: SetChromium(), "a WebKit spare was kept for pages that all open in Chromium")
    }

    @Test func thePersonsWebKitChoiceKeepsTheSpare() {
        let hosting = SetChromium()
        hosting.preference = .webkit
        expectServes(true, hosting: hosting, "the pages open in WebKit and the pool dropped their spare")
    }

    @Test func chromiumUnavailableKeepsTheSpare() {
        let hosting = SetChromium()
        hosting.isAvailable = false
        expectServes(true, hosting: hosting, "Chromium cannot host the pages and the pool dropped their WebKit spare")
    }

    @Test func onePooledPageChromiumDoesNotServeKeepsTheSpare() {
        for page in PageServedHosts.pooledDescriptors {
            let hosting = SetChromium()
            hosting.unserved = [page.id]
            expectServes(true, hosting: hosting, "\(page.id) opens in WebKit and the pool dropped its spare")
        }
    }

    @Test func noChromiumHostKeepsTheSpare() {
        expectServes(true, hosting: nil, "a WebKit-only build dropped the spare its pages open in")
    }
}
