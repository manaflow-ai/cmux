import CmuxNextActions
import Testing

/// The action catalog must resolve its localized titles from the SwiftPM
/// resource bundle. This exercises the same `Bundle.module` path used by the
/// production catalog, rather than checking the manifest text.
@Suite struct ActionCatalogLocalizationTests {
    @Test func localizedTitlesLoadFromTheActionsBundle() {
        let titles = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0.title) })

        #expect(titles["splitRight"] == "Split Right")
        #expect(titles["browser.extensions.menu"] == "Extensions…")
        #expect(titles["browser.hibernation.aggressive"] == "Hibernate Hidden Tabs After 10 Minutes")
        #expect(titles["screen.new"] == "New Screen")
        #expect(titles["browser.pageInfo"] == "View Site Information")
        #expect(titles["newTab"] == "New Workspace")
        #expect(titles["agentPane.permission.allowOnce"] == "Allow once")
        #expect(titles["agentPane.permission.allowChat"] == "Allow for this chat")
        #expect(titles["agentPane.permission.deny"] == "Deny")
        #expect(titles["agentPane.permission.expand"] == "Expand permission details")
        #expect(titles["agentPane.permission.retry"] == "Check and retry permission")
        #expect(titles["agentPane.permission.revoke"] == "Revoke chat permission")
        #expect(titles["agentPane.permission.refresh"] == "Refresh permissions")
    }
}
