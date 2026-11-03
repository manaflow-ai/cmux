import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// A failed first-run presentation must not permanently consume Bring your history. Closing a
/// successfully presented page, or upgrading an existing install, must not bring it back.
@MainActor @Suite(.serialized)
struct HistoryFirstRunRoutingTests {
    private final class HistoryPage: InternalPageProvider {
        let page = InternalPageID.importHistory
        let title = "Bring your history"
        let symbol = "square.and.arrow.down"
        var made = 0

        func makeView(for key: String, in window: WindowController?) -> NSView {
            made += 1
            return NSView()
        }
    }

    @Test func noWindowKeepsTheOfferEligibleAndAShownPageConsumesIt() throws {
        _ = NSApplication.shared
        let suite = "cmux-history-first-run-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "home.firstRun.historyImportShown"
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = HistoryPage()
        services.pages.register(page)
        services.windows.ordersWindowsIn = false

        services.onboarding.showHistoryAtFirstRun(isFirstRun: true, defaults: defaults)
        #expect(!defaults.bool(forKey: key), "no window actually presented the page")
        #expect(page.made == 0)

        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["first"], personal: ["first"]))
        let controller = try #require(services.windows.openWindow(workspaces: ["first"]))
        defer { controller.teardown(); controller.window?.close() }
        controller.state.page = .home
        services.onboarding.showHistoryAtFirstRun(isFirstRun: true, defaults: defaults)
        #expect(controller.shownTopPage == .page(.importHistory))
        #expect(defaults.bool(forKey: key))
        #expect(page.made == 1)

        _ = controller.leaveTopPage()
        controller.topPages.close(.page(.importHistory))
        services.onboarding.showHistoryAtFirstRun(isFirstRun: true, defaults: defaults)
        #expect(controller.shownTopPage != .page(.importHistory))
        #expect(page.made == 1, "closing the first presentation must not open another")
    }

    @Test func anExistingInstallationNeverGetsFirstRunHistory() throws {
        let suite = "cmux-history-upgrade-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let page = HistoryPage()
        services.pages.register(page)

        services.onboarding.showHistoryAtFirstRun(isFirstRun: false, defaults: defaults)
        #expect(defaults.bool(forKey: "home.firstRun.historyImportShown"))
        services.onboarding.showHistoryAtFirstRun(isFirstRun: true, defaults: defaults)
        #expect(page.made == 0)
    }
}
