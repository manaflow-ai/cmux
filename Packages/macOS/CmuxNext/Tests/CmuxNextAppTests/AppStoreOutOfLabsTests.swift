import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The App Store (the extensions catalog) is on for everyone, not a Labs preview. Leo, 2026-11-14:
/// "the sdk's stuff should all be hot reloadable from users' builds..." and, on taking the catalog
/// out of Labs, "yeah the whole point is for it to be usable". With `labs.previewFeatures` off (the
/// default) its actions, its sidebar item and its page all show.
@MainActor @Suite(.serialized)
struct AppStoreOutOfLabsTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    @Test func appStoreActionsAreAvailableWithLabsOff() {
        let services = Self.services()
        #expect(services.settings?.snapshot.previewFeatures != true, "the test needs Labs off, the default")
        for id: ActionID in ["appStore.show", "appStore.showInstalled"] {
            #expect(services.registry.settingOffReason(id) == nil, "\(id) is still behind Labs in menus and the palette")
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) still refuses with Labs off")
        }
    }

    @Test func sidebarDrawsTheAppStoreItemWithLabsOff() throws {
        let services = Self.services()
        #expect(services.settings?.snapshot.previewFeatures != true)
        let stored = services.sidebarLayout.document
        let ref = LayoutItemRef.app(SidebarLayoutDocument.firstPartyApps[.appStore] ?? "cmux/app-store")
        try #require(stored.firstItem(with: ref) != nil, "the default layout lists the App Store")
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"store-out-of-labs","workspace_key":"store-out-of-labs-home"}"#.utf8))
        let drawn = SidebarRows.visibleLayout(services, window: WindowState(record: record))
        #expect(drawn.firstItem(with: ref) != nil, "the sidebar leaves the App Store out with Labs off")
    }

    @Test func showingTheStoreWithLabsOffOpensIt() {
        let services = Self.services()
        #expect(services.settings?.snapshot.previewFeatures != true)
        // No window can hold it here, so the request waits for one (as Settings does) instead of being dropped.
        services.apps.showStore(focus: false)
        #expect(services.apps.isStoreWaiting, "showStore did nothing with Labs off")
    }
}
