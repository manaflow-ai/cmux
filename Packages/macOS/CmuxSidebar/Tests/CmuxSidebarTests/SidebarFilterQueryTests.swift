import Foundation
import Testing
@testable import CmuxSidebar

@Suite("SidebarFilterQuery")
struct SidebarFilterQueryTests {
    @Test func blankQueryIsEmptyAndBuildsNoMatcher() {
        for raw in ["", "   ", "\n\t"] {
            let query = SidebarFilterQuery(raw)
            #expect(query.isEmpty)
            #expect(query.makeMatcher() == nil)
        }
    }

    @Test func unprefixedQuerySearchesEveryField() {
        let query = SidebarFilterQuery("cmux")
        #expect(query.restrictedField == nil)
        #expect(query.searchText == "cmux")
        #expect(Set(query.fields) == Set(SidebarFilterField.allCases))
    }

    @Test(arguments: [
        ("@fix-drag", SidebarFilterField.branch, "fix-drag"),
        ("#infra", SidebarFilterField.group, "infra"),
        (":3000", SidebarFilterField.port, "3000"),
    ])
    func sigilScopesQueryToOneField(
        raw: String,
        expectedField: SidebarFilterField,
        expectedText: String
    ) {
        let query = SidebarFilterQuery(raw)
        #expect(query.restrictedField == expectedField)
        #expect(query.searchText == expectedText)
        #expect(query.fields == [expectedField])
    }

    @Test func bareSlashScopesToDirectory() {
        let query = SidebarFilterQuery("/repos")
        #expect(query.restrictedField == .directory)
        #expect(query.searchText == "repos")
    }

    @Test func rootedPathKeepsItsSlashAndSearchesEveryField() {
        // A user typing an absolute path is searching for that path, not
        // scoping a search to directories. Stripping the leading slash here
        // would make `/Users/me` fail to match `/Users/me`.
        let query = SidebarFilterQuery("/Users/me/src")
        #expect(query.restrictedField == nil)
        #expect(query.searchText == "/Users/me/src")
    }

    @Test func sigilAloneMatchesNothingRatherThanEverything() {
        let query = SidebarFilterQuery("@")
        #expect(query.restrictedField == .branch)
        #expect(query.isEmpty)
        #expect(query.makeMatcher() == nil)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let query = SidebarFilterQuery("  @ main  ")
        #expect(query.restrictedField == .branch)
        #expect(query.searchText == "main")
    }
}
