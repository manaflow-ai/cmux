import AppKit
import CmuxNextActions
import CmuxNextBrowser
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
    /// object is listed too (the palette's own filter follows focus at run time).
    static func paletteIDs(_ registry: ActionRegistry) -> Set<ActionID> {
        registry.context = registry.descriptors.reduce(into: ActionContext()) { $0.formUnion($1.requires) }
        return Set(RegistryPaletteProvider(registry: registry, includeUnbound: true).makeItems().compactMap(\.actionID))
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

    static func toolbarProfileMenu(_ services: AppServices) -> NSMenu {
        BrowserToolbarHandlers.profileMenu(tabKey: "tab-1", current: BrowserProfileRecord.defaultID, profiles: profiles,
                                           registry: services.registry)
    }

    @Test func everyBrowserToolbarProfileMenuRowHasAPaletteRow() {
        let services = Self.services()
        let palette = Self.paletteIDs(services.registry)
        let gaps = Self.gaps(in: [("toolbar profile menu", Self.toolbarProfileMenu(services))], registry: services.registry,
                             palette: palette)
        #expect(gaps.isEmpty, "\(gaps.count) toolbar profile menu rows with no palette row:\n\(gaps.joined(separator: "\n"))")
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
        let menu = BrowserToolbarHandlers.profileMenu(tabKey: "tab-1", current: "work", profiles: Self.profiles, registry: services.registry)
        let runs = Self.rows(menu, "").compactMap { ActionRegistry.menuRun(of: $0.1) }
        #expect(runs.filter { $0.id == "browserProfile.moveTab" }.map { $0.arguments["browserProfile"]?.stringValue } == [BrowserProfileRecord.defaultID])
        let profileRows = runs.filter { $0.target?.kind == .browserProfile }
        #expect(!profileRows.isEmpty, "no row acts on the tab's profile")
        #expect(profileRows.allSatisfy { $0.target?.id == "work" }, "rows on another profile: \(profileRows.map { "\($0.id) \($0.target?.id ?? "")" })")
    }

    /// An incognito tab's data belongs to no profile: no row clears or deletes one.
    @Test func incognitoToolbarProfileMenuHasNoProfileRows() {
        let services = Self.services()
        let menu = BrowserToolbarHandlers.profileMenu(tabKey: "tab-1", current: BrowserProfileRecord.defaultID, profiles: Self.profiles,
                                                      registry: services.registry, profileActions: false)
        let runs = Self.rows(menu, "").compactMap { ActionRegistry.menuRun(of: $0.1) }
        #expect(runs.allSatisfy { $0.target?.kind != .browserProfile }, "\(runs.map(\.id))")
    }
}
