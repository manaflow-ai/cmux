#if os(iOS)
import CmuxMobileTransport
import Foundation
import SwiftUI
import Testing
@testable import CmuxMobileBrowserStream

@MainActor @Suite struct SimulatorRetryTests {
    @Test func retryReopensAFailedSimulatorStream() async throws {
        let opener = FakeOpener()
        let model = StreamedBrowserModel(tab: "simulator", url: nil) { sink in
            try await opener.openBrowser(tab: "simulator", url: nil, sink: sink)
        }
        let rig = RedialTests()
        await rig.show(model, on: opener)
        await rig.dropLink(opener, ["simulator"])
        #expect(opener.tabs.count == 1)
        let page = StreamedSimulatorPage(model: model, insets: .init())
        await page.retry()
        await rig.until { opener.tabs.count == 2 }
        #expect(opener.tabs == ["simulator", "simulator"])
        model.setVisible(false)
        model.close()
    }
}
#endif

#if os(iOS)
/// A page's link chip counts from its Mac's link drop, not from when its stream closed: a
/// stream closes some time after the link drops, and counting from the close added that
/// time again (the review of cmux#51275).
@MainActor @Suite struct BrowserChipDownTimeTests {
    @Test func theChipCountsFromTheEarlierOfTheLinkDropAndTheClose() async throws {
        let opener = FakeOpener()
        let model = StreamedBrowserModel(tab: "page", url: nil) { sink in
            try await opener.openBrowser(tab: "page", url: nil, sink: sink)
        }
        let drop = Date(timeIntervalSince1970: 1_000)
        var link: Date? = drop
        model.linkDownSince = { link }
        let rig = RedialTests()
        await rig.show(model, on: opener)
        #expect(model.chipDownSince == drop, "the link record, before the page notices")
        await rig.dropLink(opener, ["page"])
        let closed = try #require(model.waitingSince)
        #expect(closed > drop)
        #expect(model.chipDownSince == drop, "the drop, not the close")
        link = nil
        #expect(model.chipDownSince == closed, "no link record: the page's own wait")
        model.setVisible(false)
        model.close()
    }
}
#endif
