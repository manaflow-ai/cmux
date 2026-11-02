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
    /// Keys whose PR has not landed: the tab hides their cards until the schema lists them. None
    /// now: the New Tab widgets landed with #22674 and #22775.
    static let pendingKeys: Set<String> = []

    static func make(_ json: String = "{}", recommended: [String: JSONValue] = [:]) async throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-store-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences(recommended: recommended)), managedWatchFiles: [])
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

    /// The Appearance, Editor and Mac & Phone cards (and the off-by-default toggles beside them)
    /// are landed keys, so the tab lists them, each under its own category chip.
    @Test func theOffByDefaultSettingsHaveCardsInTheirCategories() throws {
        let expected: [String: AppFeature.Category] = [
            "appearance.ultraCompact": .appearance, "appearance.calm": .appearance,
            "appearance.brailleStatus": .appearance, "appearance.runningCommands": .appearance,
            "chief.suggestedTasks": .chief, "chief.githubFeed": .chief, "chat.needsYou": .chief,
            "editor.splitDiff": .editor, "editor.minimap": .editor,
            "devices.phoneAccess": .devices, "devices.globalHotKey": .devices,
        ]
        let bridge = SettingsAppFeatures(settings: { nil })
        for (id, category) in expected {
            let feature = try Self.feature(id)
            #expect(feature.category == category, "\(id) is under \(feature.category)")
            #expect(bridge.isAvailable(feature), "\(feature.setting) is not in the schema")
            #expect(!Self.pendingKeys.contains(feature.setting))
        }
        #expect(AppFeature.Category.allCases.allSatisfy { !AppsStrings.featureCategory($0).isEmpty })
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
        bridge.openSettings(pet)
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
        // The New Tab player was this test's feature until it went off by default (u8394).
        let hoverCards = try Self.feature("sidebar.hoverCards")
        #expect(bridge.isOn(hoverCards), "on by default")
        try await bridge.set(hoverCards, on: false)
        #expect(settings.fileRoot.value(at: hoverCards.path) == .bool(false))
        #expect(!bridge.isOn(hoverCards))
    }

    /// Every card on its own key (the live toggle pass, 2026-10-21): pressing the card writes its
    /// key and nothing else and flips the card, and pressing it again flips it back and leaves the
    /// file as it found it, a default-on toggle included (its Get clears the `false`, never writes `true`).
    @Test(arguments: AppFeature.catalog.filter { $0.sidebarItem == nil }.map(\.id))
    func pressingACardTwiceTogglesItsOwnKeyAndLeavesTheFileAsItWas(_ id: String) async throws {
        let (settings, home) = try await Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        let feature = try Self.feature(id)
        guard bridge.isAvailable(feature) else {
            #expect(Self.pendingKeys.contains(feature.setting), "\(feature.setting) is not a setting")
            return
        }
        let wasOn = bridge.isOn(feature)
        try await bridge.set(feature, on: !wasOn)
        #expect(bridge.isOn(feature) == !wasOn)
        #expect(Self.leafKeys(settings.fileRoot) == [feature.setting], "\(id) wrote another key")
        try await bridge.set(feature, on: wasOn)
        #expect(bridge.isOn(feature) == wasOn)
        #expect(Self.leafKeys(settings.fileRoot).isEmpty, "\(id) left \(Self.leafKeys(settings.fileRoot)) in the file")
    }

    /// A value under the file (an MDM recommended value, or a team default) that disagrees with the
    /// press: clearing the key would let it apply, so the card writes the value the press asked for.
    @Test func aPressWinsOverARecommendedValueUnderTheFile() async throws {
        let (settings, home) = try await Self.make(recommended: ["sidebar.hoverCards.enabled": .bool(false), "home.chiefPetEnabled": .bool(true)])
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        let hoverCards = try Self.feature("sidebar.hoverCards"), pet = try Self.feature("chief.pet")
        #expect(!bridge.isOn(hoverCards) && bridge.isOn(pet), "the recommended values apply")

        try await bridge.set(hoverCards, on: true)
        #expect(bridge.isOn(hoverCards), "Get left the recommended off in effect")
        #expect(settings.fileRoot.value(at: hoverCards.path) == .bool(true))
        try await bridge.set(pet, on: false)
        #expect(!bridge.isOn(pet), "Remove left the recommended on in effect")
        #expect(settings.fileRoot.value(at: pet.path) == .bool(false))
    }

    /// Glass Window's key has no default to write back, so a recommended "glass" under the file
    /// outlasts Remove. The press says so on the card instead of quietly leaving it on.
    @Test func removeUnderARecommendationWithNothingToWriteSaysWhy() async throws {
        let (settings, home) = try await Self.make(recommended: ["appearance.backgroundBlur": .string("glass")])
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        let glass = try Self.feature("backgrounds.glass")
        #expect(bridge.isOn(glass), "the recommended value applies")

        let error = await #expect(throws: AppFeatureKeptOn.self) { try await bridge.set(glass, on: false) }
        #expect(error?.description == AppsStrings.featureKeptOn)
        #expect(bridge.isOn(glass))
        #expect(Self.leafKeys(settings.fileRoot).isEmpty, "Remove wrote \(Self.leafKeys(settings.fileRoot))")
    }

    /// The dotted keys the settings file sets (an emptied parent object sets none).
    static func leafKeys(_ value: JSONValue, prefix: String = "") -> Set<String> {
        guard let members = value.objectValue else { return [prefix] }
        return members.reduce(into: Set<String>()) { keys, member in
            keys.formUnion(leafKeys(member.value, prefix: prefix.isEmpty ? member.key : "\(prefix).\(member.key)"))
        }
    }

    /// Leo (2026-10-21): view toggles such as Expanded need no palette. Each density is a card
    /// whose Get picks it and whose Remove goes back to Compact, and the sidebar's own menu
    /// keeps every density visible (the row's ⋮ menu is trimmed, Leo 2026-10-23).
    @Test func theSidebarDensityCardsPickADensityAndTheSidebarMenuOffersThem() async throws {
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
        let ids = Set(catalog.referencedIDs(catalog.entries(for: .sidebarBackground)).map(\.rawValue))
        #expect(ids.isSuperset(of: ["sidebar.density.compact", "sidebar.density.comfortable", "sidebar.density.expanded"]),
                "the sidebar's menu offers the sidebar densities")
    }

    /// Every sidebar item the tab lists is one the sidebar's side offers (the list comes from the
    /// catalog), off in the default layout and on once the layout holds it; the Chief stays with
    /// its own sidebar. Channels writes its existing key.
    @Test func theSidebarOffersEveryListedItemAndChannelsWritesItsKey() async throws {
        let items = SidebarSectionHandlers.storeItems(chief: nil, document: { .defaults }, registry: ActionRegistry(catalog: []))
        let listed = Set(AppFeature.catalog.compactMap(\.sidebarItem))
        #expect(items.names == listed.subtracting(["chief"]))
        for name in ["search_chats", "new_terminal", "new_browser", "new_agent_chat", "customize"] {
            #expect(items.names.contains(name) && !items.isShown(name), "\(name) is offered and off by default")
            let builtIn = try #require(SidebarBuiltIn(rawValue: name))
            let op = try #require(SidebarLayoutDocument.defaults.addToTopOp(.builtIn(builtIn)))
            let document = try SidebarLayoutReducer.reduce(.defaults, op).get()
            let placed = SidebarSectionHandlers.storeItems(chief: nil, document: { document }, registry: ActionRegistry(catalog: []))
            #expect(placed.isShown(name), "\(name) is on once the sidebar shows it")
        }

        let (settings, home) = try await Self.make()
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = SettingsAppFeatures(settings: { settings })
        for id in ["chief.channels"] {
            let feature = try Self.feature(id)
            #expect(bridge.isAvailable(feature) && !bridge.isOn(feature))
            try await bridge.set(feature, on: true)
            #expect(settings.fileRoot.value(at: feature.path) == .bool(true))
            try await bridge.set(feature, on: false)
            #expect(settings.fileRoot.value(at: feature.path) == nil)
        }
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

    /// `cmux action run appStore.show --arg tab=features` (the tour, an agent, the palette).
    @Test func appStoreShowOpensANamedTab() {
        #expect(AppStoreTab(argument: " Installed ") == .installed)
        #expect(AppStoreTab(argument: "") == nil)
        #expect(AppStoreTab(argument: "features") == nil, "features are Settings now: the store opens as it is")
    }
}
