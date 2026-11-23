import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The App Store stays out of sight until it is ready (David Beyer, Nov 20 call, before the Mon Nov 23
/// launch: "don't show the app store until it's ready, it takes too much space"). It is a Labs preview
/// again: with `labs.previewFeatures` off, the default, its actions leave the palette, menus and
/// context menus, the sidebar draws no App Store item and `showStore` opens nothing. Turning Labs on
/// brings all of it back; the stored sidebar layout keeps the item either way.
@MainActor @Suite(.serialized)
struct AppStoreHiddenUntilReadyTests {
    static let storeRef = LayoutItemRef.app(SidebarLayoutDocument.firstPartyApps[.appStore] ?? "cmux/app-store")

    /// The app's services with its actions bound; with `labs`, a settings file that turns Labs on.
    static func services(labs: Bool, in directory: URL) async throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let config = directory.appending(path: "cmux.json")
        try Data(#"{"labs":{"previewFeatures":\#(labs)}}"#.utf8).write(to: config)
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

    @Test func labsIsOffByDefault() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        #expect(services.settings?.snapshot.previewFeatures != true, "Labs is on by default, so the App Store shows")
        #expect(CmuxConfigSnapshot.previewFeaturesDefault == false, "labs.previewFeatures no longer defaults to off")
    }

    @Test(arguments: [false, true])
    func storeActionsFollowLabs(labs: Bool) async throws {
        try await Self.withDirectory { directory in
            let services = try await Self.services(labs: labs, in: directory)
            for id: ActionID in ["appStore.show", "appStore.showInstalled"] {
                let off = services.registry.settingOffReason(id) != nil
                #expect(off == !labs, "\(id): palette, menus and context menus show it with Labs \(labs ? "on" : "off")? \(!off)")
                #expect((services.registry.unavailableReason(for: id) != nil) == !labs, "\(id) runs with Labs \(labs ? "on" : "off")? \(!off)")
            }
        }
    }

    @Test(arguments: [false, true])
    func sidebarDrawsTheStoreOnlyWithLabsOn(labs: Bool) async throws {
        try await Self.withDirectory { directory in
            let services = try await Self.services(labs: labs, in: directory)
            try #require(services.sidebarLayout.document.firstItem(with: Self.storeRef) != nil, "the stored default layout keeps the App Store")
            let store = try Self.drawnStoreItems(services)
            try #require(store.listed == 1, "the window's layout lists the App Store once")
            #expect(store.drawn == (labs ? 1 : 0), "the sidebar draws the App Store item with Labs \(labs ? "on" : "off")")
        }
    }

    /// A layout stored before the App Store became an app keeps it as the `app_store` built-in
    /// (SidebarLayoutDocument+RailMigration): that item hides with Labs off too.
    @Test(arguments: [false, true])
    func aStoredBuiltInStoreItemShowsOnlyWithLabsOn(labs: Bool) async throws {
        try await Self.withDirectory { directory in
            let services = try await Self.services(labs: labs, in: directory)
            let builtIn = LayoutItemRef.builtIn(.appStore)
            let layout = SidebarLayoutService()
            layout.docLayout = SidebarLayoutDocument(sections: [
                LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn,
                              items: [LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef),
                                      LayoutItem(id: LayoutItemID("itm_app_store"), ref: builtIn)]),
            ])
            services.sidebarLayout = layout
            let store = try Self.drawnStoreItems(services, ref: builtIn)
            try #require(store.listed == 1, "the window's layout lists the built-in App Store once")
            #expect(store.drawn == (labs ? 1 : 0), "the sidebar draws the built-in App Store item with Labs \(labs ? "on" : "off")")
        }
    }

    @Test(arguments: [false, true])
    func showStoreOpensOnlyWithLabsOn(labs: Bool) async throws {
        try await Self.withDirectory { directory in
            let services = try await Self.services(labs: labs, in: directory)
            // No window can hold it here, so an allowed request waits for one (as Settings does).
            services.apps.showStore(focus: false)
            #expect(services.apps.isStoreWaiting == labs, "showStore opened the App Store with Labs \(labs ? "on" : "off")")
        }
    }
}
