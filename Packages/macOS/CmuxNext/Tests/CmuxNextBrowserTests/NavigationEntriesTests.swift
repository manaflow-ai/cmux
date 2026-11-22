import Testing
@testable import CmuxNextBrowser

/// cmux_shim_tab_navigation_entries JSON. A popup window's tab can load
/// before cmux adopts it (its address event goes to no tab), so cmux reads
/// the current entry at adoption; the history menus read the list.
@Suite struct NavigationEntriesTests {
    @Test func currentEntryDecodes() throws {
        let json = #"{"current":1,"entries":[{"url":"https://a.example/","title":"A"},{"url":"https://b.example/x","title":"B"}]}"#
        let entries = try #require(CEFNavigationEntries(json: json))
        #expect(entries.entries.count == 2)
        #expect(entries.current?.url == "https://b.example/x")
        #expect(entries.current?.title == "B")
    }

    @Test func noCurrentEntry() throws {
        let entries = try #require(CEFNavigationEntries(json: #"{"current":-1,"entries":[]}"#))
        #expect(entries.current == nil)
        #expect(CEFNavigationEntries(json: "") == nil)
    }
}
