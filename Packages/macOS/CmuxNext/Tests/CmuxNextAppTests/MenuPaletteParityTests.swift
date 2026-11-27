import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextPalette
@testable import CmuxNextApp
import Testing

/// Menus and the command palette offer the same actions
/// (https://github.com/manaflow-ai/cmux/issues/42437). The browser toolbar's
/// profile menu ran private closures and offered only New and Rename, while
/// the palette (and the profile badge's menu) offered New Tab, New Window and
/// New Workspace with Browser Profile, Manage Extensions, Clear Browsing Data
/// and Delete. Every row a menu runs must be a palette row; a native AppKit
/// row names its palette action or why it has none.
@MainActor @Suite struct MenuPaletteParityTests {
    /// What a native (non-registry) menu row offers in the palette.
    enum NativeRow: Equatable {
        /// The palette row that does the same.
        case palette(ActionID)
        /// Acts on the focused text field or selection: running it from the palette would
        /// act on the palette's own field (Cut, Copy, Paste, Undo).
        case liveInput
        /// A standard macOS app-menu command that has no catalog row yet; the
        /// palette row needs a catalog addition (cmux-action-catalog step A).
        case awaitingCatalogRow
    }

    /// Every native row the menu bar keeps, by selector.
    static let nativeRows: [Selector: NativeRow] = [
        #selector(NSApplication.hide(_:)): .palette("showHideAllWindows"),
        #selector(NSApplication.hideOtherApplications(_:)): .awaitingCatalogRow,
        #selector(NSApplication.unhideAllApplications(_:)): .awaitingCatalogRow,
        #selector(NSWindow.performMiniaturize(_:)): .palette("minimizeWindow"),
        #selector(NSWindow.performZoom(_:)): .palette("zoomWindow"),
        Selector(("undo:")): .liveInput,
        Selector(("redo:")): .liveInput,
        #selector(NSText.cut(_:)): .liveInput,
        #selector(NSText.copy(_:)): .liveInput,
        #selector(NSText.paste(_:)): .liveInput,
        #selector(NSTextView.pasteAsPlainText(_:)): .liveInput,
        #selector(NSText.selectAll(_:)): .liveInput,
    ]

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    /// The ids of every palette row, with every context fact present so a row that needs a focused
    /// object is listed too (the palette's own filter follows focus at run time). A bound row that
    /// cannot run in this bare fixture (no tab, no chat) is left out of the palette until it can,
    /// so the ids of the same catalog read unbound are the palette's reach.
    static func paletteIDs(_ registry: ActionRegistry) -> Set<ActionID> {
        registry.context = registry.descriptors.reduce(into: ActionContext()) { $0.formUnion($1.requires) }
        let catalog = ActionRegistry(catalog: registry.descriptors)
        catalog.context = registry.context
        return Set(RegistryPaletteProvider(registry: catalog, includeUnbound: true).makeItems().compactMap(\.actionID))
    }

    /// What one row runs: a registry action, a native selector, nothing (a header or a checked
    /// current choice), or something else (a private closure: a gap).
    enum Run: Equatable {
        case action(ActionID)
        case native(Selector)
        case none
        case other(String)
    }

    static func run(of item: NSMenuItem) -> Run {
        if let run = ActionRegistry.menuRun(of: item) { return .action(run.id) }
        if let raw = item.representedObject as? String, item.action == NSSelectorFromString("performAction:") {
            return .action(ActionID(rawValue: raw))
        }
        guard let action = item.action else { return .none }
        if item.target == nil || item.target is NSApplication || item.target is NSWindow { return .native(action) }
        return .other("\(type(of: item.target as Any)).\(action)")
    }

    /// Every row under `menu` with a path for messages.
    static func rows(_ menu: NSMenu, _ path: String) -> [(String, NSMenuItem)] {
        menu.items.flatMap { item -> [(String, NSMenuItem)] in
            if item.isSeparatorItem { return [] }
            let here = "\(path) > \(item.title)"
            if let submenu = item.submenu { return rows(submenu, here) }
            return [(here, item)]
        }
    }

    /// The rows of `menus` that have no palette entry.
    static func gaps(in menus: [(String, NSMenu)], registry: ActionRegistry, palette: Set<ActionID>) -> [String] {
        var gaps: [String] = []
        for (name, menu) in menus {
            for (path, item) in rows(menu, name) {
                switch run(of: item) {
                case .none: continue
                case .action(let id):
                    if let gap = gap(id, registry: registry, palette: palette) { gaps.append("\(path): \(gap)") }
                case .native(let selector):
                    switch nativeRows[selector] {
                    case .palette(let id):
                        if let gap = gap(id, registry: registry, palette: palette) { gaps.append("\(path): \(gap)") }
                    case .liveInput, .awaitingCatalogRow: continue
                    case nil: gaps.append("\(path): native \(selector) names no palette row")
                    }
                case .other(let what):
                    gaps.append("\(path): runs \(what), not a palette action")
                }
            }
        }
        return gaps
    }

    /// Why `id` has no palette row, nil when it has one or declares why not.
    static func gap(_ id: ActionID, registry: ActionRegistry, palette: Set<ActionID>) -> String? {
        let id = registry.canonicalID(for: id)
        if palette.contains(id) { return nil }
        guard let descriptor = registry.descriptor(for: id) else { return "\(id) is not in the catalog" }
        // A declared exemption (a family member, the default engine's twin, a focus move) names the
        // palette row that covers it; debug actions are palette rows behind Internal Developer Mode.
        if descriptor.surfacePlan.palette.exemption != nil || descriptor.isDebugOnly { return nil }
        // A feature or setting that is off (Labs for the App Store) hides the row from menus too
        // (`ActionRegistry+Menus`), so neither surface offers it.
        if registry.disabledFeature(for: id) != nil || registry.settingOffReason(id) != nil { return nil }
        // The palette itself.
        if id == "commandPalette" { return nil }
        return "\(id) is not a palette row"
    }

    @Test func everyMenuBarRowHasAPaletteRow() {
        let services = Self.services()
        let palette = Self.paletteIDs(services.registry)
        let bar = MainMenu.make(registry: services.registry)
        let gaps = Self.gaps(in: [("menu bar", bar)], registry: services.registry, palette: palette)
        #expect(gaps.isEmpty, "\(gaps.count) menu bar rows with no palette row:\n\(gaps.joined(separator: "\n"))")
    }

    @Test func everySidebarProfileMenuRowHasAPaletteRow() {
        let services = Self.services()
        let palette = Self.paletteIDs(services.registry)
        var gaps: [String] = []
        for signedIn in [true, false] {
            let menu = ProfileMenuColumnTests.profileMenu(signedIn: signedIn, services: services)
            gaps += Self.gaps(in: [("profile menu", menu)], registry: services.registry, palette: palette)
        }
        #expect(gaps.isEmpty, "\(gaps.count) profile menu rows with no palette row:\n\(gaps.joined(separator: "\n"))")
    }

    /// Every action a right-click menu places (the catalog's menus, generated from placements).
    @Test func everyContextMenuActionHasAPaletteRow() {
        let services = Self.services()
        let registry = services.registry
        let palette = Self.paletteIDs(registry)
        var gaps: [String] = []
        for context in ActionMenuContext.allCases {
            let ids = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context))
            for id in ids {
                if let gap = Self.gap(id, registry: registry, palette: palette) { gaps.append("\(context): \(gap)") }
            }
        }
        #expect(gaps.isEmpty, "\(gaps.count) right-click rows with no palette row:\n\(gaps.joined(separator: "\n"))")
    }

    static let profiles = [
        BrowserProfileRecord(id: BrowserProfileRecord.defaultID, name: "Default"),
        BrowserProfileRecord(id: "work", name: "Work", icon: "💼", position: 1),
    ]

    /// The toolbar's profile menu for tab `tab-1`, whose profile is `current`.
    static func toolbarProfileMenu(_ services: AppServices, current: String = BrowserProfileRecord.defaultID,
                                   profileActions: Bool = true, header: (title: String, subtitle: String?, image: NSImage?)? = nil,
                                   workspace: String? = nil, style: BrowserProfileMenuStyle = .list,
                                   account: (name: String, image: NSImage?)? = nil) -> NSMenu {
        services.registry.makeBrowserProfileMenu(tabKey: "tab-1", current: current, profiles: profiles.map { ($0.id, $0.name) },
                                                 profileActions: profileActions, header: header, workspace: workspace,
                                                 style: style, account: account)
    }

    /// The menu as the toolbar's profile button opens it (cmuxterm-hq RFD 0050, D2): the tab's profile and why it has it
    /// first, running nothing; each other profile moves the tab, or with Option becomes the workspace's; then New Browser
    /// Profile and New Incognito Window, once each; Manage Browser Profiles last, opening Settings on the profiles card.
    @Test func browserToolbarProfileMenuLeadsWithTheTabsProfileAndEndsWithManage() throws {
        let services = Self.services()
        let registry = services.registry
        registry.context = registry.descriptors.reduce(into: ActionContext()) { $0.formUnion($1.requires) }
        let menu = Self.toolbarProfileMenu(services, current: "work", header: BrowserProfileBadge(monogram: "W", color: nil, name: "Work").menuHeader(.workspace),
                                           workspace: "ws-1")
        let palette = Self.paletteIDs(registry)
        let gaps = Self.gaps(in: [("toolbar profile menu with a header", menu)], registry: registry, palette: palette)
        #expect(gaps.isEmpty, "\(gaps)")

        let header = try #require(menu.items.first)
        #expect(header.identifier == ActionRegistry.browserProfileHeaderID && header.title == "Work")
        if #available(macOS 14.4, *) { #expect(header.subtitle == BrowserProfileStrings.reason(.workspace)) }
        #expect(header.image != nil)
        #expect(!header.isEnabled && ActionRegistry.menuRun(of: header) == nil)
        #expect(BrowserProfileBadge(monogram: "D", color: nil, name: "Default").menuHeader(.builtIn).subtitle == BrowserProfileStrings.reason(.builtIn))
        #expect(menu.items.filter { $0.state == .on }.isEmpty, "the header names the tab's profile: no checked row repeats it")

        let runs = menu.items.compactMap { item in ActionRegistry.menuRun(of: item).map { (item, $0) } }
        let move = try #require(runs.first { $0.1.id == "browserProfile.moveTab" })
        #expect(move.1.arguments["browserProfile"]?.stringValue == BrowserProfileRecord.defaultID && !move.0.isAlternate)
        let alternate = try #require(runs.first { $0.1.id == "browserProfile.setWorkspaceDefault" })
        #expect(alternate.0.isAlternate && alternate.0.keyEquivalentModifierMask == .option)
        #expect(menu.index(of: alternate.0) == menu.index(of: move.0) + 1, "the Option row does not follow the row it replaces")
        #expect(alternate.1.target == ActionTargetRef(kind: .workspace, id: "ws-1"))
        #expect(alternate.1.arguments["browserProfile"]?.stringValue == BrowserProfileRecord.defaultID)

        let ids = runs.map(\.1.id)
        #expect(ids.filter { $0 == "browserProfile.new" }.count == 1, "New Browser Profile shows \(ids.filter { $0 == "browserProfile.new" }.count) times")
        #expect(ids.contains("newIncognitoWindow") && ids.contains("importFromBrowser"))
        let manage = try #require(runs.last)
        #expect(manage.1.id == "openSettings" && manage.0 === menu.items.last)
        #expect(manage.1.arguments["section"]?.stringValue == "rooms" && manage.1.arguments["setting"]?.stringValue == "card.browserProfiles")
        // No separator first, last or doubled.
        let separators = menu.items.map(\.isSeparatorItem)
        #expect(separators.first == false && separators.last == false)
        #expect(!zip(separators, separators.dropFirst()).contains { $0 && $1 }, "two separators in a row")
    }

    @Test(arguments: BrowserProfileMenuStyle.allCases) func everyBrowserToolbarProfileMenuRowHasAPaletteRow(style: BrowserProfileMenuStyle) {
        let services = Self.services()
        let palette = Self.paletteIDs(services.registry)
        let header = BrowserProfileBadge(monogram: "D", color: nil, name: "Default").menuHeader(.builtIn)
        let gaps = Self.gaps(in: [("toolbar profile menu", Self.toolbarProfileMenu(services, header: header, style: style,
                                                                                   account: ("leo@example.com", nil))),
                                  ("incognito toolbar profile menu", Self.toolbarProfileMenu(services, profileActions: false, style: style))],
                             registry: services.registry, palette: palette)
        #expect(gaps.isEmpty, "\(gaps.count) toolbar profile menu rows with no palette row:\n\(gaps.joined(separator: "\n"))")
    }

    /// Settings > Experiments > Browser Profile Card off (the default): the button opens cmux#51248's menu, no card, no
    /// account row, no avatars on the other profiles (Leo's UI hold, 2026-11-25).
    @Test func browserToolbarProfileMenuIsTodaysWhileTheCardExperimentIsOff() throws {
        let services = Self.services()
        #expect(!DesignSettings.shared.experiment("browserProfileCard"))
        let menu = BrowserToolbarHandlers.profileMenu(forTab: "tab-1", services: services)
        #expect(!menu.items.contains { $0.view != nil || $0.identifier == ActionRegistry.browserProfileAccountID
            || $0.identifier == ActionRegistry.browserProfileCustomizeID })
        let carded = BrowserToolbarHandlers.profileMenu(forTab: "tab-1", services: services, style: .card)
        #expect(carded.items.first?.view is MenuProfileCardView)
    }

    /// The look the experiment opens (Leo 2026-11-25, Helium's profile menu): the card leads, with who is signed in to cmux
    /// under it opening Accounts; New Browser Profile, New Incognito Window and Manage Browser Profiles sit together;
    /// the profile's own rows are one level down, in Customize Profile; Import from Browser and the Web Store end it.
    @Test func browserToolbarProfileMenuCardLeadsWithTheProfileCard() throws {
        let services = Self.services()
        let registry = services.registry
        registry.context = registry.descriptors.reduce(into: ActionContext()) { $0.formUnion($1.requires) }
        let menu = Self.toolbarProfileMenu(services, current: "work", header: BrowserProfileBadge(monogram: "W", color: nil, name: "Work")
            .menuHeader(.workspace), workspace: "ws-1", style: .card, account: ("leo@example.com", nil))

        let header = try #require(menu.items.first)
        #expect(header.identifier == ActionRegistry.browserProfileHeaderID && !header.isEnabled)
        let card = try #require(header.view as? MenuProfileCardView)
        #expect(card.title == "Work" && card.subtitle == BrowserProfileStrings.reason(.workspace) && card.image != nil)

        let account = try #require(menu.items.dropFirst().first)
        #expect(account.identifier == ActionRegistry.browserProfileAccountID && account.title.contains("leo@example.com"))
        #expect(ActionRegistry.menuRun(of: account)?.id == "accounts.show")

        let runs = menu.items.compactMap { item in ActionRegistry.menuRun(of: item).map { (item, $0.id) } }
        let ids = runs.map(\.1)
        let new = try #require(ids.firstIndex(of: "browserProfile.new"))
        #expect(Array(ids[new...].prefix(3)) == ["browserProfile.new", "newIncognitoWindow", "openSettings"],
                "New Browser Profile, New Incognito Window and Manage Browser Profiles sit together: \(ids)")
        #expect(ids.suffix(2) == ["importFromBrowser", "browser.extensions.webStore"])
        #expect(!ids.contains("browserProfile.rename"), "the profile's own rows are in Customize Profile, not at the top level")

        let customize = try #require(menu.items.first { $0.identifier == ActionRegistry.browserProfileCustomizeID })
        let inside = Self.rows(try #require(customize.submenu), "").compactMap { ActionRegistry.menuRun(of: $0.1)?.id }
        #expect(inside.contains("browserProfile.rename") && inside.contains("browserProfile.delete") && !inside.contains("browserProfile.new"))

        // Signed out: no account row. Incognito: no card, no Customize Profile.
        let signedOut = Self.toolbarProfileMenu(services, header: BrowserProfileBadge(monogram: "D", color: nil, name: "Default")
            .menuHeader(.builtIn), style: .card)
        #expect(!signedOut.items.contains { $0.identifier == ActionRegistry.browserProfileAccountID })
        let incognito = Self.toolbarProfileMenu(services, profileActions: false, style: .card)
        #expect(!incognito.items.contains { $0.identifier == ActionRegistry.browserProfileCustomizeID || $0.view != nil })
        for shown in [menu, signedOut, incognito] {
            let separators = shown.items.map(\.isSeparatorItem)
            #expect(separators.first == false && separators.last == false)
            #expect(!zip(separators, separators.dropFirst()).contains { $0 && $1 }, "two separators in a row")
        }
    }

    /// The other way: the toolbar's profile menu offers every action of the profile's own menu
    /// (the badge's, generated from the `browserProfile` placements), and each other profile moves
    /// the tab there with `browserProfile.moveTab`.
    @Test func browserToolbarProfileMenuOffersEveryProfileAction() {
        let services = Self.services()
        let registry = services.registry
        registry.context = registry.descriptors.reduce(into: ActionContext()) { $0.formUnion($1.requires) }
        func shownIDs(_ menu: NSMenu) -> Set<ActionID> {
            Set(Self.rows(menu, "").compactMap { _, item -> ActionID? in
                if case .action(let id) = Self.run(of: item) { return id }
                return nil
            })
        }
        let menu = Self.toolbarProfileMenu(services)
        let rows = Self.rows(menu, "toolbar profile menu").map(\.1)
        let shown = shownIDs(menu)
        // What the profile's badge menu offers for the same profile and tab.
        let badge = shownIDs(registry.makeContextMenu(for: .browserProfile, target: ActionTargetRef(kind: .browserProfile, id: BrowserProfileRecord.defaultID),
                                                      arguments: ["tab": .target(ActionTargetRef(kind: .tab, id: "tab-1"))], customize: false))
        let required: Set<ActionID> = [
            "browserProfile.newTab", "browserProfile.newWindow", "browserProfile.newWorkspace", "browserProfile.new",
            "browserProfile.rename", "browserProfile.manageExtensions", "browserProfile.clearBrowsingData",
        ]
        let missing = badge.union(required).subtracting(shown)
        #expect(missing.isEmpty, "the toolbar profile menu lacks \(missing.map(\.rawValue).sorted())")
        let moves = rows.compactMap(ActionRegistry.menuRun(of:)).filter { $0.id == "browserProfile.moveTab" }
        #expect(moves.map { $0.arguments["browserProfile"]?.stringValue } == ["work"], "moves: \(moves.map(\.arguments))")
        #expect(moves.allSatisfy { $0.target == ActionTargetRef(kind: .tab, id: "tab-1") })
    }

    /// A tab of another profile: its rows act on that profile, and Default is the row that moves it.
    @Test func browserToolbarProfileMenuActsOnTheTabsProfile() {
        let services = Self.services()
        let menu = Self.toolbarProfileMenu(services, current: "work")
        let runs = Self.rows(menu, "").compactMap { ActionRegistry.menuRun(of: $0.1) }
        #expect(runs.filter { $0.id == "browserProfile.moveTab" }.map { $0.arguments["browserProfile"]?.stringValue } == [BrowserProfileRecord.defaultID])
        let profileRows = runs.filter { $0.target?.kind == .browserProfile }
        #expect(!profileRows.isEmpty, "no row acts on the tab's profile")
        #expect(profileRows.allSatisfy { $0.target?.id == "work" }, "rows on another profile: \(profileRows.map { "\($0.id) \($0.target?.id ?? "")" })")
    }

    /// An incognito tab's data belongs to no profile: no row clears or deletes one. New Browser Profile
    /// and the tab's extensions, which touch no profile's data, stay.
    @Test func incognitoToolbarProfileMenuHasNoProfileRows() {
        let services = Self.services()
        let registry = services.registry
        registry.context = registry.descriptors.reduce(into: ActionContext()) { $0.formUnion($1.requires) }
        let menu = Self.toolbarProfileMenu(services, profileActions: false)
        let runs = Self.rows(menu, "").compactMap { ActionRegistry.menuRun(of: $0.1) }
        #expect(runs.allSatisfy { $0.target?.kind != .browserProfile }, "\(runs.map(\.id))")
        let ids = Set(runs.map(\.id))
        #expect(ids.isSuperset(of: ["browserProfile.new", "browser.extensions.manage", "importFromBrowser"]), "\(ids)")
    }
}
