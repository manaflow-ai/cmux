import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

/// A reconnect can publish a workspace with a tab missing for a moment: its streamed page
/// (select-menu sheet, JS alert) must survive that, and still go once the tab stays gone.
@MainActor @Suite struct ReconnectKeepsBrowserTabsTests {
    private func until(_ check: () -> Bool) async {
        for _ in 0..<400 where !check() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aTabMissingFromOnePublishKeepsItsModel() async throws {
        let directory = StreamedBrowserDirectory()
        directory.missingGrace = .seconds(30)
        let opener = FakeOpener()
        directory.opener = { opener }
        let page = try #require(directory.model(tab: "s1", url: nil))
        directory.retain(tabs: ["s2"])
        #expect(directory.model(tab: "s1", url: nil) === page, "one partial publish does not close the page")
        directory.retain(tabs: ["s1", "s2"])
        directory.retain(tabs: ["s2"])
        #expect(directory.model(tab: "s1", url: nil) === page, "the grace restarts once the tab is listed again")
    }

    @Test func aTabThatStaysMissingIsClosedAfterTheGrace() async throws {
        let directory = StreamedBrowserDirectory()
        directory.missingGrace = .milliseconds(100)
        let opener = FakeOpener()
        directory.opener = { opener }
        let page = try #require(directory.model(tab: "s1", url: nil))
        directory.retain(tabs: ["s2"])
        #expect(directory.model(tab: "s1", url: nil) === page)
        // Nothing publishes again: the directory looks once more when the grace ends.
        await until { directory.model(tab: "s1", url: nil) !== page }
        #expect(directory.model(tab: "s1", url: nil) !== page)
    }
}
