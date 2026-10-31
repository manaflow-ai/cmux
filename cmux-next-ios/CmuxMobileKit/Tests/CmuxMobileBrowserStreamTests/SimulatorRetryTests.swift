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
