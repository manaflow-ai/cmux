@testable import CmuxNextSettings
import Testing

/// #26384: the opt-in for each workspace's tabs in the sidebar is easy to find. Settings >
/// Appearance > Sidebar lists Show Workspace Tabs as its first row, the row says off by default,
/// and a search for the words people use ("panes", "tabs under workspaces") finds it.
struct SidebarShowWorkspaceTabsSettingsRowTests {
    private static let key = "sidebar.showWorkspaceTabs"

    private static var descriptor: SettingDescriptor? { SettingsSchema.all.first { $0.id == key } }

    @Test func firstRowOfAppearanceSidebarCard() throws {
        let appearance = try #require(SettingsPageLayout().categories().first { $0.spec.id == "appearance" })
        let sidebar = try #require(appearance.groups.first { $0.key == "settings.group.sidebar" })
        #expect(sidebar.title.text == "Sidebar")
        #expect(sidebar.rows.first == Self.key, "\(sidebar.rows.prefix(3))")
    }

    @Test func toggleTitledShowWorkspaceTabsOffByDefault() throws {
        let row = try #require(Self.descriptor)
        #expect(row.isShownOnSettingsPage)
        #expect(row.title == "Show Workspace Tabs")
        #expect(row.defaultValue == .bool(false))
    }

    @Test func searchWordsFindIt() throws {
        let row = try #require(Self.descriptor)
        for word in ["panes", "tabs", "under", "workspaces", "nested"] {
            #expect(row.keywords.contains(word), "\(word) not in \(row.keywords)")
        }
    }
}
