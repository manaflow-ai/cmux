import CmuxNextActions
import CmuxNextApps
@testable import CmuxNextApp
import CmuxNextCloudUI
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The Automations page is reachable (docs/automations-platonic-ideal.md section 8, option A): one
/// "Automations" sidebar item that opens the page on top (off by default like the Chief item; Add
/// to Sidebar adds it), `automations.show` in Cmd+Shift+P and the CLI, Automations offered to Add to Sidebar and the App Store's sidebar features, and a
/// page provider that loads this Mac's automations from the bundled CLI and Cloud ones through
/// `cloud.automation`, with failures counted on the item's badge.
@MainActor
struct AutomationsEntryTests {
    @Test func theSidebarItemOpensTheAutomationsTopPageAndIsOffByDefault() {
        #expect(SidebarBuiltIn(rawValue: "automations") == .automations)
        #expect(SidebarBridge.builtInActions[.automations] == "automations.show")
        #expect(TopPageRoute.route(for: .builtIn(.automations)) == .page(.automations))
        #expect(SidebarLayoutDocument.defaults.firstItem(with: .builtIn(.automations)) == nil)
        #expect(!SidebarBuiltIn.automations.title.isEmpty)
        #expect(TopPageRoute(rawValue: TopPageRoute.page(.automations).rawValue) == .page(.automations))
        #expect(AppFeature.catalog.contains { $0.on == .sidebarItem("automations") })
        let add = ActionCatalog.all.first { $0.id == "sidebar.item.add" }
        #expect(add?.arguments.first?.suggestions?.pinned.map(\.value).contains("automations") == true)
    }

    @Test func thePaletteOffersShowAndNew() throws {
        let ids = Set(ActionCatalog.all.map(\.id))
        #expect(ids.contains("automations.show"))
        let show = try #require(ActionCatalog.all.first { $0.id == "automations.show" })
        #expect(show.surfaces.contains(.palette))
        #expect(show.cliName == "automation show-page")
    }

    @Test func thePageHostLoadsBothSourcesAndCountsFailures() async {
        let local = Data("""
        {"automations": [{"id": "auto_aaaaaaaaaaaaaaaaaaaa", "name": "Deps", "enabled": true, "trigger": {"type": "manual"},
          "body": {"type": "command", "command": "true"}, "next_run_at": null, "last_run": {"state": "failed"}}]}
        """.utf8)
        let cloud = Data(#"{"automations": [{"id": "auto_bbbbbbbbbbbbbbbbbbbb", "name": "Brief", "enabled": true, "triggers": [], "body": {"type": "chief", "prompt": "hi"}, "next_run_at": null}]}"#.utf8)
        let host = AutomationsPageHost(local: { local }, cloud: { cloud })
        await host.model.reload(now: .now)
        #expect(host.model.rows.map(\.name).sorted() == ["Brief", "Deps"])
        #expect(host.model.badgeCount == 1)
        #expect(host.makeView(tokens: { ThemeScope.app.tokens }).fittingSize.width >= 0)
    }

    /// The Cloud source reads the relay's `value`: a refusal (signed out, Cloud off) is an error the
    /// page shows, not an empty list.
    @Test func theCloudSourceUnwrapsTheRelayAnswer() throws {
        let ok = Data(#"{"ok": true, "value": {"automations": []}}"#.utf8)
        #expect(try AutomationsPageHost.cloudValue(ok) == Data(#"{"automations":[]}"#.utf8))
        let refused = Data(#"{"ok": false, "error": {"code": "automation.signed_out", "message": "sign in"}}"#.utf8)
        #expect(throws: AutomationsPageHost.SourceError.self) { try AutomationsPageHost.cloudValue(refused) }
    }
}
