import CmuxNextActions
@testable import CmuxNextAgentLanes
@testable import CmuxNextApps
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextSettingsWindow
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// The App Store's Features tab (Leo, 2026-10-20: finished features are App Store items, not
/// Labs flags): every card is one existing cmux-next.json key, Get writes its on value, Remove
/// puts it back to off, and a card follows a write made anywhere else.
@MainActor @Suite(.serialized) struct AppStoreFeaturesTests {
    /// Keys whose PR has not landed: the tab hides their cards until the schema lists them
    /// (tabs.newTabWidgets.*, #22674 and #22775; the Priority view's key, lane priority-view).
    static let pendingKeys: Set<String> = [
        "tabs.newTabWidgets.projects", "tabs.newTabWidgets.actions", "tabs.newTabWidgets.chats", "tabs.newTabWidgets.modeSwitch",
        "tabs.newTabWidgets.weather", "tabs.newTabWidgets.machines", "sidebar.priorityView.enabled",
    ]

    static func make(_ json: String = "{}") async throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-store-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, home)
    }

    static func feature(_ id: String) throws -> AppFeature {
        try #require(AppFeature.catalog.first { $0.id == id })
    }

    @Test func everyFeatureIsAnExistingSettingWithAValidOnValue() {
        #expect(Set(AppFeature.catalog.map(\.id)).count == AppFeature.catalog.count, "feature ids are unique")
        for feature in AppFeature.catalog {
            // A sidebar item is a built-in the default layout does not show, so Get adds it.
            if let item = feature.sidebarItem {
                let builtIn = SidebarBuiltIn(rawValue: item)
                #expect(builtIn != nil, "\(item) is not a sidebar item")
                #expect(builtIn.flatMap { SidebarLayoutDocument.defaults.firstItem(with: .builtIn($0)) } == nil, "\(feature.id) is on by default")
                #expect(!feature.name.isEmpty && !feature.summary.isEmpty)
                continue
            }
            guard let descriptor = SettingsSchema.descriptor(for: feature.path) else {
                #expect(Self.pendingKeys.contains(feature.setting), "\(feature.setting) is not a setting")
                continue
            }
            switch feature.on {
            case .toggle: #expect(descriptor.kind == .toggle, "\(feature.setting) is not on/off")
            case .choice: #expect(descriptor.accepts(SettingsAppFeatures.onValue(feature)), "\(feature.setting) refuses \(feature.id)'s value")
            case .sidebarItem: break // above
            }
            #expect(!feature.name.isEmpty && !feature.summary.isEmpty)
            // A choice that is on by default could not be turned off by Remove (it clears the key);
            // a default-on toggle (Now Playing on New Tab) is written false instead.
            if case .choice = feature.on {
                #expect(descriptor.effectiveValue(in: .object([:])) != SettingsAppFeatures.onValue(feature),
                        "\(feature.id) is on by default, so Remove could not turn it off")
            }
        }
    }

    /// The Chief Pet card's Settings… link opens Settings > Chief Pet (Settings on its key's rows);
    /// a card whose feature names no rows, or an app that cannot show Settings, has no link.
    @Test func theChiefPetCardLinksToItsSettings() throws {
        for feature in AppFeature.catalog {
            guard let key = feature.settingsLink else { continue }
            // The anchor Settings scrolls to (`SettingsWindowService.show(setting:)`), not just a schema key.
            #expect(SettingsAnchor(key: key) != nil, "\(feature.id) links to \(key), which Settings cannot show")
        }
        var shown: [String] = []
        let bridge = SettingsAppFeatures(settings: { nil }, showSettings: { shown.append($0) })
        let pet = try Self.feature("chief.pet")
        #expect(bridge.hasSettings(pet))
        AppStoreModel(client: AppsClient(transport: FeaturesOfflineAppsTransport()), features: bridge).openSettings(pet)
        #expect(shown == ["home.chiefPetEnabled"])

        let perPane = try Self.feature("backgrounds.perPane")
        #expect(!bridge.hasSettings(perPane))
        bridge.openSettings(perPane)
        #expect(shown == ["home.chiefPetEnabled"], "a feature with no settings rows opened Settings")
        #expect(!SettingsAppFeatures(settings: { nil }).hasSettings(pet), "a link that cannot open Settings is shown")
    }

    @Test func getWritesTheOnValueAndRemoveTurnsItOff() async throws {
        let (settings, home) = try await Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        let pet = try Self.feature("chief.pet")
        #expect(bridge.isAvailable(pet))
        #expect(!bridge.isOn(pet))

        try await bridge.set(pet, on: true)
        #expect(settings.snapshot.homeChiefPetEnabled)
        #expect(bridge.isOn(pet))
        try await bridge.set(pet, on: false)
        #expect(!settings.snapshot.homeChiefPetEnabled)
        #expect(settings.fileRoot.value(at: pet.path) == nil, "off is the default, so the key leaves the file")

        // A choice: Get picks it, Remove clears the key so the default (no background) applies.
        let paintings = try Self.feature("backgrounds.shufflePaintings")
        try await bridge.set(paintings, on: true)
        #expect(settings.fileRoot.value(at: ["appearance", "background"]) == .string("daily"))
        #expect(bridge.isOn(paintings))
        let wallpaper = try Self.feature("backgrounds.desktopWallpaper")
        #expect(!bridge.isOn(wallpaper), "one background at a time")
        try await bridge.set(paintings, on: false)
        #expect(settings.fileRoot.value(at: ["appearance", "background"]) == nil)
        #expect(!bridge.isOn(paintings))
    }

    /// Chief in Sidebar: listed once the sidebar binds its side, on while the layout shows the
    /// Chief item, and Get / Remove run the sidebar's edit; a refused edit says so on the card.
    @Test func aSidebarItemCardAddsAndRemovesTheItem() async throws {
        final class Sidebar { var shown = false, refuses = false, edits: [String] = [] }
        let saved = SettingsAppFeatures.sidebarItems
        defer { SettingsAppFeatures.sidebarItems = saved }
        let bridge = SettingsAppFeatures(settings: { nil })
        let card = try Self.feature("chief.sidebarItem")
        SettingsAppFeatures.sidebarItems = nil
        #expect(!bridge.isAvailable(card))
        let sidebar = Sidebar()
        SettingsAppFeatures.sidebarItems = .init(names: ["chief"], isShown: { _ in sidebar.shown }, set: { name, on in
            sidebar.edits.append("\(on ? "add" : "remove") \(name)")
            guard !sidebar.refuses else { return false }
            sidebar.shown = on
            return true
        })
        #expect(bridge.isAvailable(card))
        #expect(!bridge.isOn(card))
        #expect(!bridge.isManaged(card))
        try await bridge.set(card, on: true)
        #expect(bridge.isOn(card))
        try await bridge.set(card, on: false)
        #expect(!bridge.isOn(card))
        sidebar.refuses = true
        await #expect(throws: SettingRefused.self) { try await bridge.set(card, on: true) }
        #expect(sidebar.edits == ["add chief", "remove chief", "add chief"])
    }

    /// The Chief card's edits are the sidebar's own actions: Add to Sidebar with the item's name,
    /// Remove from Sidebar on the item, both as the person's.
    @Test func theChiefCardRunsTheSidebarsAddAndRemove() {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        var runs: [String] = []
        registry.bind("sidebar.item.add", invoke: { runs.append("add \($0["item"]?.stringValue ?? "") \($0.origin == .user)") })
        registry.bind("sidebar.item.removeEverywhere", invoke: {
            runs.append("remove \($0.target?.kind == .sidebarItem ? $0.target?.id ?? "" : "") \($0.origin == .user)")
        })
        #expect(ChiefSidebar.setPlaced("chief", true, registry: registry))
        #expect(ChiefSidebar.setPlaced("chief", false, registry: registry))
        #expect(!ChiefSidebar.setPlaced("chief", true, registry: nil))
        #expect(runs == ["add chief true", "remove chief true"])
    }

    @Test func removeWritesFalseForAFeatureThatIsOnByDefault() async throws {
        let (settings, home) = try await Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        let newTabPlayer = try Self.feature("newTab.nowPlaying")
        #expect(bridge.isOn(newTabPlayer), "on by default")
        try await bridge.set(newTabPlayer, on: false)
        #expect(settings.fileRoot.value(at: newTabPlayer.path) == .bool(false))
        #expect(!bridge.isOn(newTabPlayer))
    }

    /// Leo (2026-10-21): view toggles such as Expanded need no palette. Each density is a card
    /// whose Get picks it and whose Remove goes back to Compact, and a workspace row's ⋮ menu
    /// offers the densities that are not in effect.
    @Test func theSidebarDensityCardsPickADensityAndTheRowMenuOffersThem() async throws {
        let (settings, home) = try await Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        let comfortable = try Self.feature("sidebar.comfortable"), expanded = try Self.feature("sidebar.expanded")
        #expect(bridge.isAvailable(expanded) && !bridge.isOn(expanded) && !bridge.isOn(comfortable))

        try await bridge.set(expanded, on: true)
        #expect(settings.snapshot.sidebarSections.density == .expanded)
        try await bridge.set(comfortable, on: true)
        #expect(settings.snapshot.sidebarSections.density == .comfortable)
        #expect(bridge.isOn(comfortable) && !bridge.isOn(expanded), "one density at a time")
        try await bridge.set(comfortable, on: false)
        #expect(settings.snapshot.sidebarSections.density == .compact)
        #expect(settings.fileRoot.value(at: comfortable.path) == nil)

        let catalog = ContextMenuCatalog.shared
        let ids = Set(catalog.referencedIDs(catalog.entries(for: .workspaceRow)).map(\.rawValue))
        #expect(ids.isSuperset(of: ["sidebar.density.compact", "sidebar.density.comfortable", "sidebar.density.expanded"]),
                "a workspace row's ⋮ menu offers the sidebar densities")
    }

    @Test func aCardFollowsAWriteMadeElsewhere() async throws {
        let (settings, home) = try await Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        let player = try Self.feature("media.sidebar")
        #expect(!bridge.isOn(player))
        // `cmux settings set sidebar.nowPlaying.enabled true`, or the Settings window.
        try await settings.set(.bool(true), at: player.path)
        #expect(bridge.isOn(player))
    }

    @Test func theTabListsLandedFeaturesFilteredBySearchAndCategory() async throws {
        let (settings, home) = try await Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppStoreModel(client: AppsClient(transport: FeaturesOfflineAppsTransport()))
        #expect(model.featureListings.isEmpty, "a store without settings lists no features")
        let bridge = SettingsAppFeatures(settings: { settings })
        model.features = bridge

        let listed = model.featureListings
        #expect(listed.allSatisfy(bridge.isAvailable))
        #expect(listed.count == AppFeature.catalog.filter(bridge.isAvailable).count)
        #expect(listed.contains { $0.id == "chief.pet" })

        model.featureCategory = .backgrounds
        #expect(!model.featureListings.isEmpty)
        #expect(model.featureListings.allSatisfy { $0.category == .backgrounds })
        model.featureCategory = nil
        model.query = "chief pet"
        #expect(model.featureListings.map(\.id) == ["chief.pet"])
        model.query = "home.chiefPetEnabled"
        #expect(model.featureListings.map(\.id) == ["chief.pet"], "the key is searchable")
    }

    /// `cmux action run appStore.show --arg tab=features` (the tour, an agent, the palette).
    @Test func appStoreShowOpensANamedTab() {
        #expect(AppStoreModel.Tab(argument: "features") == .features)
        #expect(AppStoreModel.Tab(argument: " Installed ") == .installed)
        #expect(AppStoreModel.Tab(argument: "") == nil)
        #expect(AppStoreModel.Tab(argument: "labs") == nil, "an unknown tab opens the store as it is")

        let model = AppStoreModel(client: AppsClient(transport: FeaturesOfflineAppsTransport()))
        model.present(appID: nil, tab: .features)
        #expect(model.tab == .features)
        #expect(model.canGoBack, "opening a tab is a page navigation")
    }
}

/// An app supervisor that is never reachable (the Features tab does not need one).
private final class FeaturesOfflineAppsTransport: AppsTransport {
    var availability: AppsAvailability { .unavailable(.notConnected) }
    var onEvent: ((AppsTransportEvent) -> Void)?
    private static var offline: AppsTransportError { AppsTransportError(message: "offline", connectionLost: true) }

    func start() {}
    func list() async throws(AppsTransportError) -> AppsListReply { throw Self.offline }
    func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
        throw Self.offline
    }
    func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) { throw Self.offline }
    func unmount(mountID: String) async throws(AppsTransportError) { throw Self.offline }
    func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) { throw Self.offline }
    func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
        throw Self.offline
    }
    func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { throw Self.offline }
}
