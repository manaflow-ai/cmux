import AppKit
import CmuxNextBridge
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextSidebar
import CmuxNextTabs
import Testing

/// Lane 20: Settings opens as a tab (an internal page) in the focused pane
/// of the active window, not as a window of its own; every entry point
/// (Cmd-, palette, sidebar, CLI) runs `openSettings`. One tab per page per
/// window: opening it again selects the tab it has.
@MainActor
@Suite(.serialized)
struct InternalPageTabTests {
    @Test func pageIDsRoundTrip() {
        let key = LocalPageTab.makeKey(.debugSettings)
        #expect(key.hasPrefix("local-page:debug-settings:"))
        #expect(LocalPageTab.page(of: key) == .debugSettings)
        #expect(LocalPageTab.page(of: "local-agent:x") == nil)
        #expect(LocalPageTab.page(of: "local-page:") == nil)
    }

    /// A main window with one pane and loaded settings (scratch cmux.json).
    private func world() async throws -> (AppServices, WindowController, PaneController) {
        try await world(before: { _ in })
    }

    /// `world()`, running `before` once settings load and before the window opens.
    private func world(before: (AppServices) throws -> Void) async throws -> (AppServices, WindowController, PaneController) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = ActionBindingCoverageTests.boundServices()
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        services.windows.ordersWindowsIn = false
        try before(services)
        let store = services.daemon.store
        store.apply(snapshot: try BrowserTabTests.tree())
        let workspace = try #require(store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        await BrowserTabTests.settle { window.content != nil }
        let content = try #require(window.content)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let paneID = LayoutPaneIDFixture.id(paneModel)
        await BrowserTabTests.settle { content.panes[paneID] != nil }
        if content.panes[paneID] == nil { _ = content.makeContentView(for: paneID) }
        let pane = try #require(content.panes[paneID])
        content.layoutModel.focus(paneID)
        return (services, window, pane)
    }

    @Test func openSettingsOpensATabNotAWindow() async throws {
        let (services, window, pane) = try await world()
        let windowsBefore = NSApp.windows.count
        #expect(services.registry.perform("openSettings", invocation: ActionInvocation()))

        let keys = services.pages.keys(of: .settings)
        #expect(keys.count == 1)
        let key = try #require(keys.first)
        #expect(pane.orderedIDs.map(\.rawValue).contains(key))
        await BrowserTabTests.settle { pane.stripModel.selectedID?.rawValue == key }
        #expect(pane.stripModel.selectedID?.rawValue == key, "a user run selects the Settings tab")
        #expect(services.settingsWindow.window === window.window, "Settings lives in the main window")
        #expect(NSApp.windows.count == windowsBefore, "no Settings window was made")
        #expect(pane.focusPane.tabs.first { $0.id == key }?.kind == .page)

        // Again: the same tab, no second one.
        services.registry.perform("openSettings", invocation: ActionInvocation())
        #expect(services.pages.keys(of: .settings) == [key])
    }

    @Test func automationOpensTheTabWithoutTakingTheSelection() async throws {
        let (services, _, pane) = try await world()
        let selected = pane.stripModel.selectedID
        services.registry.perform("openSettings", invocation: ActionInvocation(origin: .cli))
        let key = try #require(services.pages.keys(of: .settings).first)
        #expect(pane.orderedIDs.map(\.rawValue).contains(key))
        #expect(pane.stripModel.selectedID == selected)
    }

    @Test func closingTheTabDropsItsPage() async throws {
        let (services, _, pane) = try await world()
        services.registry.perform("openSettings", invocation: ActionInvocation())
        let key = try #require(services.pages.keys(of: .settings).first)
        _ = pane.content(for: key)
        #expect(services.pages.existingView(key) != nil)
        pane.close([StripTabID(key)])
        #expect(services.pages.keys(of: .settings).isEmpty)
        #expect(services.pages.existingView(key) == nil)
        #expect(!pane.orderedIDs.map(\.rawValue).contains(key))
    }

    @Test func cmdWClosesTheSelectedSettingsTabThroughTheSharedAction() async throws {
        let (services, _, pane) = try await world()
        services.registry.perform("openSettings", invocation: ActionInvocation())
        let key = try #require(services.pages.keys(of: .settings).first)
        await BrowserTabTests.settle { pane.stripModel.selectedID?.rawValue == key }

        #expect(services.registry.perform("closeTab", invocation: ActionInvocation()))
        #expect(services.pages.keys(of: .settings).isEmpty)
        #expect(!pane.orderedIDs.map(\.rawValue).contains(key))
    }

    @Test func thePageViewIsTheTabContentAndTakesTheKeyboard() async throws {
        let (services, _, pane) = try await world()
        services.registry.perform("openSettings", invocation: ActionInvocation())
        let key = try #require(services.pages.keys(of: .settings).first)
        guard case .page(let view)? = pane.content(for: key) else {
            Issue.record("a Settings tab shows a page view")
            return
        }
        #expect(view.page == .settings)
        #expect(view.focusTarget.isDescendant(of: view))
        #expect(services.pages.stripItem(key).title == SettingsPaneTitle.text)
    }

    /// R82: the tab shows the React Settings page (cmux-page://cmux.settings/), not the Swift view.
    @Test func theSettingsTabIsTheReactPage() async throws {
        let (services, _, pane) = try await world()
        services.registry.perform("openSettings", invocation: ActionInvocation())
        let key = try #require(services.pages.keys(of: .settings).first)
        guard case .page(let view)? = pane.content(for: key) else {
            Issue.record("a Settings tab shows a page view")
            return
        }
        let page = try #require(view.content as? PageWebView, "the Settings tab hosts the React page")
        #expect(page.pageID == "cmux.settings")
        #expect(page.themeSurface == .settings, "appearance.surfaces.settings colors the page, as it colored the Swift view")
    }

    /// R82 commit 6: with no main window, Settings… makes no window of its own. The request waits,
    /// and the first window that shows a workspace opens the React page tab on the asked section.
    @Test func withNoWindowSettingsWaitsForAWindowAndOpensThePageThere() async throws {
        let (services, _, pane) = try await world { services in
            let windowsBefore = NSApp.windows.count
            let arguments: [String: ActionValue] = ["section": .string("browser")]
            #expect(services.registry.perform("openSettings", invocation: ActionInvocation(arguments: arguments)))
            #expect(NSApp.windows.count == windowsBefore, "no Settings window was made")
            #expect(services.pages.keys(of: .settings).isEmpty)
        }
        await BrowserTabTests.settle { !services.pages.keys(of: .settings).isEmpty }
        let key = try #require(services.pages.keys(of: .settings).first, "the waiting request opens the tab")
        #expect(pane.orderedIDs.map(\.rawValue).contains(key))
        guard case .page(let view)? = pane.content(for: key), let page = view.content as? PageWebView else {
            Issue.record("a Settings tab shows the React page")
            return
        }
        #expect(page.route == "#/settings/browser")
    }

    /// Every way into the old appearance studio (the action from the palette, the View menu, a
    /// shortcut or `cmux settings customize-appearance`, and the sidebar item, which runs the same
    /// action) lands on Settings > Appearance in the React page (R82 commit 6).
    @Test func customizeAppearanceLandsOnSettingsAppearance() async throws {
        let (services, _, pane) = try await world()
        let action = try #require(SidebarBridge.builtInActions[.customize])
        #expect(action == "appearance.customize")
        #expect(services.registry.perform(action, invocation: ActionInvocation()))
        let key = try #require(services.pages.keys(of: .settings).first, "Customize Appearance opens the Settings tab")
        guard case .page(let view)? = pane.content(for: key), let page = view.content as? PageWebView else {
            Issue.record("a Settings tab shows the React page")
            return
        }
        #expect(page.route == "#/settings/appearance")
        #expect(pane.stripModel.selectedID?.rawValue == key, "a user run selects the tab")
    }

    /// A deep link to a schema setting opens the React page on that row
    /// (`#/settings/<section>?focus=<key>`).
    @Test func aSettingDeepLinkFocusesTheRowInThePage() async throws {
        let (services, _, pane) = try await world()
        let arguments: [String: ActionValue] = ["setting": .string("appearance.density")]
        services.registry.perform("openSettings", invocation: ActionInvocation(arguments: arguments))
        let key = try #require(services.pages.keys(of: .settings).first)
        guard case .page(let view)? = pane.content(for: key), let page = view.content as? PageWebView else {
            Issue.record("a Settings tab shows the React page")
            return
        }
        #expect(page.route == "#/settings/appearance?focus=appearance.density")
    }

    /// Keyboard opens the React Keyboard Shortcuts page; Accounts opens in the React page (R82
    /// commit 3), so no section opens the Swift window any more.
    @Test func keyboardGoesToItsPageAndAccountsToTheReactPage() async throws {
        let (services, _, _) = try await world()
        services.registry.perform("openSettings", invocation: ActionInvocation(arguments: ["section": .string("keyboard")]))
        #expect(services.pages.keys(of: .keybindings).count == 1, "Keyboard opens the Keyboard Shortcuts page")
        #expect(services.pages.keys(of: .settings).isEmpty)
        services.registry.perform("openSettings", invocation: ActionInvocation(arguments: ["section": .string("accounts")]))
        #expect(services.pages.keys(of: .settings).count == 1, "Accounts opens the React Settings tab")
        services.registry.perform("accounts.show", invocation: ActionInvocation())
        #expect(services.pages.keys(of: .settings).count == 1, "accounts.show selects the same tab")
    }

    /// R82 commit 2: Spaces & Profiles and Machines open in the React page, and its host lists
    /// carry the app's spaces, machines, browser profiles and profile colors.
    @Test func spacesAndMachinesOpenInTheReactPage() async throws {
        let (services, _, pane) = try await world()
        services.registry.perform("openSettings", invocation: ActionInvocation(arguments: ["section": .string("machines")]))
        let key = try #require(services.pages.keys(of: .settings).first, "Machines opens the React Settings tab")
        guard case .page(let view)? = pane.content(for: key), let page = view.content as? PageWebView else {
            Issue.record("a Settings tab shows the React page")
            return
        }
        #expect(page.route == "#/settings/machines")
        services.registry.perform("openSettings", invocation: ActionInvocation(arguments: ["setting": .string("card.browserProfiles")]))
        #expect(page.route == "#/settings/rooms", "a card anchor opens its section")
        let lists = services.settingsWindow.pageHostLists()
        #expect(lists["machines"]?.arrayValue != nil)
        #expect(lists["browser_profiles"]?.arrayValue != nil)
        #expect(lists["profile_colors"]?.arrayValue?.count == GroupColor.allCases.count)
    }
}
