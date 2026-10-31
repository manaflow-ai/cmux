import CmuxNextActions
@testable import CmuxNextApps
@testable import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// One sidebar and no cmux Classic Mode for everyone (Lawrence 2026-10-30: "wtf is cmux classic mode
/// get rid of it", "i dont want to see tabs expanded inside of sidebar"). A fresh profile and an old
/// cmux.json that turned either on both get the plain workspace list: no tab rows under a workspace,
/// no disclosure on its row, and no Settings row, palette action or App Store feature for either.
@MainActor struct ClassicModeRemovedTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func snapshot(_ root: JSONValue = .object([:])) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    /// Two workspaces with tabs, as the sidebar of a person with a few windows open.
    static func sections() -> [SidebarSection] {
        var shell = SidebarWorkspace(id: WorkspaceID("shell"), title: "shell")
        shell.tabs = [SidebarTab(id: TabID("t1"), title: "zsh"), SidebarTab(id: TabID("t2"), title: "logs")]
        shell.focusedTab = TabID("t1")
        var web = SidebarWorkspace(id: WorkspaceID("web"), title: "web")
        web.tabs = [SidebarTab(id: TabID("t3"), title: "cmux.com", kind: .browser)]
        return [SidebarSection(kind: .machine(machine), nodes: [.workspace(shell), .workspace(web)])]
    }

    /// The rows the sidebar lays out for `snapshot`'s `sidebar.*` settings.
    static func rows(_ snapshot: CmuxConfigSnapshot) -> [SidebarRow] {
        let model = SidebarModel(sections: sections())
        model.applyListPreferences(snapshot.sidebarSections)
        return SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions()).rows
    }

    static func tabRows(_ rows: [SidebarRow]) -> [SidebarRowKey] {
        rows.map(\.key).filter { if case .tab = $0 { true } else { false } }
    }

    @Test func aFreshProfileListsNoTabsInsideTheSidebar() {
        let rows = Self.rows(Self.snapshot())
        #expect(Self.tabRows(rows).isEmpty, "a fresh profile lists tabs under its workspaces: \(Self.tabRows(rows))")
        #expect(rows.allSatisfy { $0.tabDisclosure == nil }, "a workspace row draws a tab disclosure")
        #expect(rows.contains { if case .workspace = $0.key { true } else { false } }, "the workspaces still list")
    }

    @Test func anOldFileThatListedTabsGetsTheSameSidebarQuietly() {
        let snapshot = Self.snapshot(.object(["sidebar": .object(["showWorkspaceTabs": .bool(true)])]))
        #expect(Self.tabRows(Self.rows(snapshot)).isEmpty)
        #expect(snapshot.diagnostics.isEmpty, "a retired key loads without a warning: \(snapshot.diagnostics)")
        #expect(snapshot.retiredKeys.contains("sidebar.showWorkspaceTabs"))
    }

    @Test func anOldFileWithClassicModeOnLoadsQuietly() {
        let snapshot = Self.snapshot(.object(["tabs": .object(["terminalFirst": .bool(true)])]))
        #expect(snapshot.diagnostics.isEmpty, "a retired key loads without a warning: \(snapshot.diagnostics)")
        #expect(snapshot.retiredKeys.contains("tabs.terminalFirst"))
        #expect(SettingsSchema.isRetired(["tabs", "terminalFirst"]))
        #expect(SettingsSchema.isRetired(["sidebar", "showWorkspaceTabs"]))
    }

    @Test func settingsPaletteAndStoreOfferNeither() {
        #expect(SettingsSchema.descriptor(for: ["tabs", "terminalFirst"]) == nil)
        #expect(SettingsSchema.descriptor(for: ["sidebar", "showWorkspaceTabs"]) == nil)
        let classic = SettingsSchema.all.filter { $0.title.localizedCaseInsensitiveContains("classic mode") }
        #expect(classic.isEmpty, "Settings still lists \(classic.map(\.id))")
        #expect(!ActionCatalog.all.contains { $0.id == "sidebar.workspaceTabs.toggle" })
        let features = AppFeature.catalog.filter { ["tabs.terminalFirst", "sidebar.showWorkspaceTabs"].contains($0.setting) }
        #expect(features.isEmpty, "the App Store still offers \(features.map(\.id))")
    }
}
