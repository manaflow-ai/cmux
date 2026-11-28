@testable import CmuxNextBrowser
import Testing

@Suite struct CEFChatPagePoolTests {
    @Test func offByDefaultAndListed() {
        #expect(CEFChatPagePool.setting.descriptor.key == "browserPage.chatPagePool")
        #expect(BrowserPageTunables.all.contains { $0.key == CEFChatPagePool.setting.key })
        #expect(CEFChatPagePool.capacity == 2)
    }
}
