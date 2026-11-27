@testable import CmuxNextBrowser
import Foundation
import Testing

/// Closed chats' garbage in the shared cmux-page renderer (`CEFPageRendererGC`): one check per renderer that hosts
/// cmux pages, through one of its live pages, and a full collection only past the bound.
@MainActor @Suite struct CEFPageRendererGCTests {
    typealias Page = CEFPageRendererGC.Page
    typealias Target = CEFPageRendererGC.Target
    static let mb = 1 << 20

    @Test func oneCheckPerCmuxPageRenderer() {
        let pages = [
            Page(browser: 12, isCmuxPage: true, rendererClients: [6]),
            Page(browser: 4, isCmuxPage: true, rendererClients: [6]),
            Page(browser: 9, isCmuxPage: true, rendererClients: [8, 6]),
            Page(browser: 2, isCmuxPage: false, rendererClients: [6]),
            Page(browser: 3, isCmuxPage: false, rendererClients: [11]),
            Page(browser: 7, isCmuxPage: true, rendererClients: []),
        ]
        #expect(CEFPageRendererGC.targets(pages) == [Target(renderer: 6, browser: 4), Target(renderer: 8, browser: 9)])
        #expect(CEFPageRendererGC.targets([Page(browser: 1, isCmuxPage: false, rendererClients: [3])]).isEmpty)
    }

    @Test func theBoundIsTwiceWhatWasLiveAndAtLeastTheFloorMore() {
        #expect(CEFPageRendererGC.bound(afterLastCollection: nil) == 128 * Self.mb)
        #expect(CEFPageRendererGC.bound(afterLastCollection: 10 * Self.mb) == 74 * Self.mb)
        #expect(CEFPageRendererGC.bound(afterLastCollection: 90 * Self.mb) == 180 * Self.mb)
    }

    @MainActor final class Renderers {
        var used: [Int32: Int] = [4: 546 * CEFPageRendererGCTests.mb, 9: 100 * CEFPageRendererGCTests.mb]
        var collected: [Int32] = []
    }

    @Test func aRendererPastItsBoundIsCollectedOnceAndItsLiveSizeKept() async {
        let renderers = Renderers()
        let gc = CEFPageRendererGC(
            pages: { [Page(browser: 4, isCmuxPage: true, rendererClients: [6]), Page(browser: 9, isCmuxPage: true, rendererClients: [8])] },
            heapUsed: { renderers.used[$0] },
            collect: { browser in
                renderers.collected.append(browser)
                renderers.used[browser] = 91 * Self.mb
            })
        await gc.check()
        #expect(renderers.collected == [4])
        // Garbage grows again below twice the 91 MB left live: no second blocking collection.
        renderers.used[4] = 170 * Self.mb
        await gc.check()
        #expect(renderers.collected == [4])
        renderers.used[4] = 190 * Self.mb
        await gc.check()
        #expect(renderers.collected == [4, 4])
    }

    @Test func theQuietBoundIsTheQuietFloorMoreThanWasLive() {
        #expect(CEFPageRendererGC.quietBound(afterLastCollection: nil) == 16 * Self.mb)
        #expect(CEFPageRendererGC.quietBound(afterLastCollection: 40 * Self.mb) == 56 * Self.mb)
        #expect(CEFPageRendererGC.quietBound(afterLastCollection: 40 * Self.mb) < CEFPageRendererGC.bound(afterLastCollection: 40 * Self.mb))
    }

    @Test func theQuietCheckCollectsTheLastBurstsGarbageBelowTheBound() async {
        let renderers = Renderers()
        renderers.used = [4: 200 * Self.mb]
        let gc = CEFPageRendererGC(
            pages: { [Page(browser: 4, isCmuxPage: true, rendererClients: [6])] },
            heapUsed: { renderers.used[$0] },
            collect: { browser in
                renderers.collected.append(browser)
                renderers.used[browser] = 40 * Self.mb
            })
        await gc.check()
        #expect(renderers.collected == [4])
        // The last closes leave 60 MB of garbage: under twice what is live, so the burst's check keeps it.
        renderers.used[4] = 100 * Self.mb
        await gc.check()
        #expect(renderers.collected == [4])
        // Once closes stop, the quiet check collects it, twice (the second returns what the first unhooked).
        await gc.check(quiet: true)
        #expect(renderers.collected == [4, 4, 4])
        #expect(gc.stats["quiet_collections"] == 1)
        #expect(gc.stats["quiet_second_collections"] == 1)
        // Less than the quiet floor of garbage: nothing.
        renderers.used[4] = 50 * Self.mb
        await gc.check(quiet: true)
        #expect(renderers.collected == [4, 4, 4])
    }

    @Test func readsUsedSizeAndTheScheme() async {
        #expect(await CEFPageRendererGC.usedSize(#"{"usedSize":142032280,"totalSize":181190656}"#) == 142_032_280)
        #expect(await CEFPageRendererGC.usedSize("{}") == nil)
        #expect(CEFPageRendererGC.isCmuxPage(URL(string: "cmux-page://cmux.agent/")))
        #expect(!CEFPageRendererGC.isCmuxPage(URL(string: "https://example.com/")))
        #expect(!CEFPageRendererGC.isCmuxPage(nil))
    }
}
