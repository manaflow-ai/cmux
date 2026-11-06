@testable import CmuxNextApp
import CmuxNextPages
import Testing

/// Home's New Cloud Machine (webviews/src/pages/home-channels ConversationList): the page reaches the
/// app's own `newCloudMachine` action through `cmux.app.action.run`, and no other app action.
struct HomeChannelsCloudEntryTests {
    @Test func theChannelsPageRunsOnlyNewCloudMachine() {
        let page = PageDescriptor.homeChannels
        #expect(page.admits(PageNativeOp.actionRun))
        #expect(page.actions == ["newCloudMachine"])
        #expect(page.confirmedOps.isEmpty)
    }
}
