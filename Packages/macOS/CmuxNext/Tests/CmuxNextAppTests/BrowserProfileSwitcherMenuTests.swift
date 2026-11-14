import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/42438: the omnibar's profile avatar opens Chrome's profile menu.
/// Before, its menu only offered New Tab / Window / Workspace with Browser Profile, Rename,
/// Appearance, extensions, Clear Browsing Data and Delete, so a person could not switch the tab's
/// profile from it. Now: the tab's profile as the header, Other Profiles (one click moves the tab
/// into one), Add, Guest and Manage, and the profile's own actions kept below. Runs the app's
/// registry against a same-tree cmux-tui daemon and clicks the switch row as the menu does.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct BrowserProfileSwitcherMenuTests {
    private static func rows(_ menu: NSMenu) -> [NSMenuItem] {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items)
    }

    private static func browserTabs(_ pane: PaneController, _ services: AppServices) -> [TabModel] {
        services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).filter { $0.id == pane.pane.id }.flatMap(\.tabs).filter { $0.kind == .browser }
    }

    @Test func theAvatarMenuSwitchesTheTabToAnotherProfileInOneClick() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            defer { for key in Array(services.cache.browsers.keys) { services.cache.release(key) } }
            let name = "Switch \(UUID().uuidString.prefix(6))"
            let id = try await services.browserProfiles.createProfile(name: name, color: "blue", icon: nil)
            try await PasswordManagerRouteTests.until({ services.browserProfiles.ordered.contains { $0.id == id } },
                                                       report: { "profiles \(services.browserProfiles.ordered.map(\.name))" })
            // A fresh state has not moved its records to the daemon yet: the daemon gets the same profile too,
            // as a migrated install has it, because the daemon moves a tab only into a profile it holds.
            if !services.browserProfiles.usesDaemonRecords {
                _ = try await connection.createBrowserProfile(CreateBrowserProfileRequest(id: id, name: name, color: "blue"))
            }
            let other = try #require(services.browserProfiles.ordered.first { $0.name == name })
            defer { try? services.browserProfiles.delete(other.id) }

            let pane = try #require(services.windows.active?.focusedPane)
            let surface = try await connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit, in: pane.pane.handle, activate: false).surface
            try await PasswordManagerRouteTests.until({ services.daemon.store.tab(surface: surface).flatMap { services.cache.tabModel($0.id) } != nil },
                                                       report: { WindowStateReport.describe(services, surface: surface) })
            let tab = try #require(services.daemon.store.tab(surface: surface))
            #expect(services.browserProfiles.profileID(ofTab: tab) == BrowserProfileRecord.defaultID)

            let menu = try #require(services.cache.profileBadgeMenu?(tab.id), "the avatar has no menu")
            let items = menu.items
            // Header first: the tab's own profile.
            #expect(items.first?.identifier?.rawValue == "browserProfile.switcher.current", "the menu does not open on the current profile")
            let profiles = services.browserProfiles
            #expect(items.first?.title == (profiles.record(BrowserProfileRecord.defaultID)?.name ?? profiles.displayName(BrowserProfileRecord.defaultID)))
            // The other profile, as a row that moves this tab into it.
            let switchRow = try #require(items.first { $0.identifier?.rawValue == "browserProfile.switch.\(other.id)" },
                                         "no row to switch to \(name): \(items.map(\.title))")
            #expect(switchRow.title == name)
            #expect(switchRow.image != nil, "the profile row has no avatar")
            let run = try #require(ActionRegistry.menuRun(of: switchRow))
            #expect(run.id == "browserProfile.moveTab")
            #expect(run.target == ActionTargetRef(kind: .tab, id: tab.id))
            #expect(run.arguments["browserProfile"]?.stringValue == other.id)
            // The current profile is not offered as a switch.
            #expect(!items.contains { $0.identifier?.rawValue == "browserProfile.switch.\(BrowserProfileRecord.defaultID)" })
            // Option: the same profile for the whole workspace.
            let alternate = try #require(items.first { $0.isAlternate && ActionRegistry.menuRun(of: $0)?.id == "browserProfile.setWorkspaceDefault" })
            #expect(ActionRegistry.menuRun(of: alternate)?.arguments["browserProfile"]?.stringValue == other.id)

            // Add, Guest and Manage, then the profile's actions it had before.
            let ids = Self.rows(menu).compactMap { ActionRegistry.menuRun(of: $0)?.id.rawValue }
            for id in ["browserProfile.new", "newIncognitoWindow", "openSettings"] {
                #expect(ids.contains(id), "no \(id) row: \(ids)")
            }
            #expect(Self.rows(menu).first { ActionRegistry.menuRun(of: $0)?.id == "openSettings" }
                .flatMap { ActionRegistry.menuRun(of: $0)?.arguments["setting"]?.stringValue } == "card.browserProfiles")
            for id in ["browserProfile.newTab", "browserProfile.newWindow", "browserProfile.newWorkspace", "browserProfile.rename",
                       "browserProfile.clearBrowsingData", "browserProfile.delete"] {
                #expect(ids.contains(id), "the profile's own \(id) row is gone: \(ids)")
            }
            #expect(ids.filter { $0 == "browserProfile.new" }.count == 1, "New Browser Profile shows twice")
            let switchIndex = try #require(items.firstIndex(of: switchRow))
            let renameIndex = try #require(items.firstIndex { ActionRegistry.menuRun(of: $0)?.id == "browserProfile.rename" })
            #expect(switchIndex < renameIndex, "the profile list is not above the profile's actions")

            // One click: what `ActionMenuTarget.performAction` runs for it. The tab reopens in the other profile.
            #expect((switchRow.target as? any NSMenuItemValidation)?.validateMenuItem(switchRow) == true, "the switch row is disabled")
            let refusal = services.registry.capturingRefusal {
                _ = services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments))
            }
            #expect(refusal == nil, "the switch refused: \(refusal ?? "")")
            try await PasswordManagerRouteTests.until({ Self.browserTabs(pane, services).contains { services.browserProfiles.profileID(ofTab: $0) == other.id } },
                                                       within: .seconds(30), report: {
                "tabs \(Self.browserTabs(pane, services).map { "\($0.id): \(services.browserProfiles.profileID(ofTab: $0))" })"
            })
            #expect(!Self.browserTabs(pane, services).contains { $0.id == tab.id && services.browserProfiles.profileID(ofTab: $0) == BrowserProfileRecord.defaultID },
                    "the tab also stayed in the default profile")
        }
    }
}
