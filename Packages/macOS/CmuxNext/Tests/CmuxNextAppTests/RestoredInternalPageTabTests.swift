import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextIcons
import CmuxNextSettingsWindow
import CmuxNextTabs
import Observation
import os
import Testing

/// A restored page can reach the strip before its provider registers. It stays named and
/// badged, then adopts the provider without restoring its route or making a view early.
@MainActor
struct RestoredInternalPageTabTests {
    private final class Page: InternalPageProvider {
        let page: InternalPageID
        var title = "Review changes"
        var symbol = "plusminus"
        var icon: IconName?
        var restored: [(route: String, key: String)] = []
        var made = 0

        init(_ page: InternalPageID) { self.page = page }
        func restore(_ route: String, for key: String) { restored.append((route, key)) }
        func makeView(for key: String, in window: WindowController?) -> NSView {
            made += 1
            return NSView()
        }
    }

    private static func restoredTab(_ page: InternalPageID, route: String? = nil) throws -> (DaemonStore, TabModel) {
        let store = DaemonStore()
        var tab = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank")
        tab.conversation = ConversationTabRef(page: page.rawValue, route: route)
        let pane = PaneSnapshot(id: 1, tabs: [tab])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return (store, try #require(store.tab(surface: 1)))
    }

    @Test func aLocalPageHasATitleAndIconBeforeItsProviderRegisters() {
        let pages = InternalPageTabStore()
        let key = LocalPageTab.makeKey(.settings)
        let item = pages.stripItem(key)
        #expect(item.title == SettingsDeepLink.pageTitle)
        #expect(item.icon == .icon(.fileText))
        #expect(pages.view(for: key) == nil)
        let unknown = InternalPageID(rawValue: "extension-page")
        #expect(pages.stripItem(LocalPageTab.makeKey(unknown)).title == unknown.rawValue)
    }

    @Test func aRestoredWhatsNewTabHasItsLocalizedTitleWithoutAProvider() throws {
        let pages = InternalPageTabStore()
        let (_, tab) = try Self.restoredTab(.changelog)
        let item = try #require(pages.storeTabItem(tab))
        #expect(item.title == ChangelogPageStrings.title)
        #expect(item.icon == .icon(.fileText))
        #expect(TabTitleResolver(pages: pages).title(tab) == ChangelogPageStrings.title)
    }

    /// Only the App Store is a Labs preview page; What's New is not (next test).
    @Test func restoredPreviewPagesWaitForThePreviewSetting() throws {
        let page = InternalPageID.appStore
        let pages = InternalPageTabStore()
        let provider = Page(page)
        pages.register(provider)
        let (store, tab) = try Self.restoredTab(page, route: "saved-route")
        #expect(pages.view(forStoreTab: tab, in: store, local: true, window: nil) == nil)
        let key = pages.open(page, in: "preview-pane", of: store)
        #expect(pages.view(for: key) == nil)
        #expect(provider.made == 0)
        #expect(provider.restored.isEmpty)
    }

    /// A restored What's New tab restores with Labs off: an update's See What's New opens it
    /// (user 13935, Leo 2026-10-29), so the page is not held back like the App Store.
    @Test func aRestoredWhatsNewTabRestoresWithLabsOff() throws {
        let pages = InternalPageTabStore()
        let provider = Page(.changelog)
        pages.register(provider)
        let (store, tab) = try Self.restoredTab(.changelog, route: "saved-route")
        // No window: no settings, so Labs reads off.
        let view = try #require(pages.view(forStoreTab: tab, in: store, local: true, window: nil))
        #expect(view.page == .changelog)
        #expect(provider.restored.first?.route == "saved-route")
        let key = pages.open(.changelog, in: "preview-pane", of: store)
        #expect(pages.view(for: key) != nil)
        #expect(provider.made == 2)
    }

    @Test func lateRegistrationRefreshesTheStripAndRestoresTheViewOnlyOnce() throws {
        let pages = InternalPageTabStore()
        let page = InternalPageID(rawValue: "late-page")
        let (store, tab) = try Self.restoredTab(page, route: "saved-route")
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = pages.storeTabItem(tab) } onChange: { changed.withLock { $0 = true } }
        #expect(pages.view(forStoreTab: tab, in: store, local: true, window: nil) == nil)
        #expect(pages.storeKey(of: tab.id) == nil)

        let provider = Page(page)
        provider.icon = .fileText
        pages.register(provider)
        #expect(changed.withLock { $0 })
        let item = try #require(pages.storeTabItem(tab))
        #expect(item.title == provider.title)
        #expect(item.icon == .icon(.fileText))
        #expect(provider.restored.isEmpty)
        #expect(provider.made == 0)
        let view = try #require(pages.view(forStoreTab: tab, in: store, local: true, window: nil))
        #expect(pages.view(forStoreTab: tab, in: store, local: true, window: nil) === view)
        #expect(provider.restored.count == 1)
        #expect(provider.restored.first?.route == "saved-route")
        #expect(provider.made == 1)
    }

    @Test func registeredProvidersKeepTheirTitleAndSymbolInBothStrips() throws {
        let pages = InternalPageTabStore()
        let provider = Page(InternalPageID(rawValue: "review"))
        pages.register(provider)
        let local = pages.stripItem(LocalPageTab.makeKey(provider.page))
        let (_, tab) = try Self.restoredTab(provider.page)
        let restored = try #require(pages.storeTabItem(tab))
        #expect(local.title == provider.title)
        #expect(restored.title == provider.title)
        #expect(local.icon == .symbol(provider.symbol))
        #expect(restored.icon == .symbol(provider.symbol))
    }

    @Test func anEmptyProviderTitleStillHasAFallback() throws {
        let pages = InternalPageTabStore()
        let provider = Page(.settings)
        provider.title = " \n "
        pages.register(provider)
        let (_, tab) = try Self.restoredTab(.settings)
        #expect(pages.stripItem(LocalPageTab.makeKey(.settings)).title == SettingsDeepLink.pageTitle)
        #expect(pages.storeTabItem(tab)?.title == SettingsDeepLink.pageTitle)
    }
}
