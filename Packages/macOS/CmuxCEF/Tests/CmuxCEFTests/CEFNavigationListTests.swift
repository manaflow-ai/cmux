import Foundation
import Testing
@testable import CmuxCEF

@Suite
struct CEFNavigationListTests {
    @Test
    func shimEntriesSplitIntoBackAndForwardListsNearestFirst() throws {
        let json = """
        {"current":2,"entries":[
          {"url":"https://a.test/","title":"A"},
          {"url":"https://b.test/","title":""},
          {"url":"https://c.test/","title":"C"},
          {"url":"https://d.test/","title":"D"}
        ]}
        """
        let list = try #require(CEFNavigationList(json: json))

        #expect(list.currentIndex == 2)
        #expect(list.current?.url == URL(string: "https://c.test/"))
        #expect(list.backEntries.map(\.url) == [URL(string: "https://b.test/"), URL(string: "https://a.test/")])
        #expect(list.backEntries.map(\.title) == [nil, "A"])
        #expect(list.forwardEntries.map(\.url) == [URL(string: "https://d.test/")])
        // Offsets count from the current entry, as `goToEntry(offset:)` takes them.
        #expect(list.backEntries.map(\.offset) == [-1, -2])
        #expect(list.forwardEntries.map(\.offset) == [1])
    }

    @Test
    func malformedOrEmptyShimReplyListsNothing() {
        #expect(CEFNavigationList(json: "") == nil)
        #expect(CEFNavigationList(json: "{\"current\":0}") == nil)
        #expect(CEFNavigationList(json: "{\"current\":-1,\"entries\":[]}") == nil)
    }

    @Test
    func outOfRangeCurrentIndexHasNoBackOrForwardEntries() throws {
        let list = try #require(CEFNavigationList(json: "{\"current\":5,\"entries\":[{\"url\":\"https://a.test/\",\"title\":\"A\"}]}"))
        #expect(list.current == nil)
        #expect(list.backEntries.isEmpty)
        #expect(list.forwardEntries.isEmpty)
    }

    @MainActor @Test
    func browserWithoutChromiumListsNothingAndCannotJump() {
        let runtime = CEFRuntime(layout: nil)
        let browser = CEFBrowser(
            configuration: CEFBrowserConfiguration(profile: UUID(), initialURL: URL(string: "https://example.com/")),
            runtime: runtime
        )
        #expect(browser.navigationList() == nil)
        #expect(browser.goToEntry(offset: -1) == false)
    }
}
