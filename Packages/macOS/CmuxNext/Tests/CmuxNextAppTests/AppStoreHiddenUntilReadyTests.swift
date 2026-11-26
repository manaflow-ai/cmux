import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The App Store stays out of sight until it is ready (David Beyer, Nov 20 call: "don't show the app
/// store until it's ready, it takes too much space"; Lawrence, Nov 23: "get rid of app store from
/// default for now"). It has its own switch, `labs.appStore`, off by default: while it is off its
/// actions leave the palette, menus and context menus, the sidebar draws no App Store item and
/// `showStore` opens nothing, also with Labs' Show Preview Features (`labs.previewFeatures`) on, which
/// other previews (music, hints, stats) ask people to turn on. Turning `labs.appStore` on brings all of
/// it back; the stored sidebar layout keeps the item either way.
@MainActor @Suite(.serialized)
struct AppStoreHiddenUntilReadyTests {
    static let storeRef = LayoutItemRef.app(SidebarLayoutDocument.firstPartyApps[.appStore] ?? "cmux/app-store")

    /// Each pair of Show Preview Features (`labs`) and the App Store's own switch (`store`).
    nonisolated static let switches: [(labs: Bool, store: Bool)] = [(false, false), (true, false), (false, true), (true, true)]

    /// The app's services with its actions bound, reading a settings file that sets Show Preview
    /// Features to `labs` and the App Store's switch to `store`.
    static func services(labs: Bool, store: Bool, in directory: URL) async throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let config = directory.appending(path: "cmux.json")
        try Data(#"{"labs":{"previewFeatures":\#(labs),"appStore":\#(store)}}"#.utf8).write(to: config)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: services.registry, design: DesignSettings(), fileURL: config,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        #expect(settings.snapshot.previewFeatures == labs, "the settings file did not set Labs")
        return services
    }

    static func withDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-store-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    static func label(_ labs: Bool, _ store: Bool) -> String {
        "Show Preview Features \(labs ? "on" : "off"), labs.appStore \(store ? "on" : "off")"
    }

    /// The App Store items the window's sidebar draws, as its band reads them (`SidebarView.updateBands`):
    /// the layout's App Store items less those the sidebar hides, in the turn that makes the sidebar.
    static func drawnStoreItems(_ services: AppServices, ref: LayoutItemRef = storeRef) throws -> (listed: Int, drawn: Int) {
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"store-hidden","workspace_key":"store-hidden-home"}"#.utf8))
        let bridge = SidebarBridge(services: services, state: WindowState(record: record))
        defer { bridge.teardown() }
        let sections = bridge.model.layout.sections
        let hidden = SidebarItemInfo.hiddenItems(in: sections, infos: bridge.model.resolvedItemInfo)
        let store = sections.flatMap(\.items).filter { $0.ref == ref }
        return (store.count, store.filter { !hidden.contains($0.id) }.count)
    }

    @Test func theStoreIsOffByDefault() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.settings?.snapshot.showsAppStore != true, "a default app shows the App Store")
        #expect(CmuxConfigSnapshot.previewFeaturesDefault == false, "labs.previewFeatures no longer defaults to off")
    }

    @Test(arguments: switches)
    func storeActionsFollowTheirOwnSwitch(labs: Bool, store: Bool) async throws {
        try await Self.withDirectory { directory in
            let services = try await Self.services(labs: labs, store: store, in: directory)
            for id: ActionID in ["appStore.show", "appStore.showInstalled"] {
                let off = services.registry.settingOffReason(id) != nil
                #expect(off == !store, "\(id): palette, menus and context menus show it with \(Self.label(labs, store))? \(!off)")
                #expect((services.registry.unavailableReason(for: id) != nil) == !store, "\(id) runs with \(Self.label(labs, store))? \(!off)")
            }
        }
    }

    @Test(arguments: switches)
    func sidebarDrawsTheStoreOnlyWithItsSwitchOn(labs: Bool, store: Bool) async throws {
        try await Self.withDirectory { directory in
            let services = try await Self.services(labs: labs, store: store, in: directory)
            try #require(services.sidebarLayout.document.firstItem(with: Self.storeRef) != nil, "the stored default layout keeps the App Store")
            let items = try Self.drawnStoreItems(services)
            try #require(items.listed == 1, "the window's layout lists the App Store once")
            #expect(items.drawn == (store ? 1 : 0), "the sidebar draws the App Store item with \(Self.label(labs, store))")
        }
    }

    /// A layout stored before the App Store became an app keeps it as the `app_store` built-in
    /// (SidebarLayoutDocument+RailMigration): that item follows the same switch.
    @Test(arguments: switches)
    func aStoredBuiltInStoreItemShowsOnlyWithItsSwitchOn(labs: Bool, store: Bool) async throws {
        try await Self.withDirectory { directory in
            let services = try await Self.services(labs: labs, store: store, in: directory)
            let builtIn = LayoutItemRef.builtIn(.appStore)
            let layout = SidebarLayoutService()
            layout.docLayout = SidebarLayoutDocument(sections: [
                LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                              items: [LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef),
                                      LayoutItem(id: LayoutItemID("itm_app_store"), ref: builtIn)]),
            ])
            services.sidebarLayout = layout
            let items = try Self.drawnStoreItems(services, ref: builtIn)
            try #require(items.listed == 1, "the window's layout lists the built-in App Store once")
            #expect(items.drawn == (store ? 1 : 0), "the sidebar draws the built-in App Store item with \(Self.label(labs, store))")
        }
    }

    @Test(arguments: switches)
    func showStoreOpensOnlyWithItsSwitchOn(labs: Bool, store: Bool) async throws {
        try await Self.withDirectory { directory in
            let services = try await Self.services(labs: labs, store: store, in: directory)
            // No window can hold it here, so an allowed request waits for one (as Settings does).
            services.apps.showStore(focus: false)
            #expect(services.apps.isStoreWaiting == store, "showStore opened the App Store with \(Self.label(labs, store))")
        }
    }
}
