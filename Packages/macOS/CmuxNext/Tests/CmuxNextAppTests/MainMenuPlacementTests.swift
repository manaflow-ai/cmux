import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextPalette
@testable import CmuxNextApp
import Testing

/// Every catalog action placed in a main menu (`mainMenu`) shows in the
/// built menu bar under that top menu (menu audit S10/S11, hq #2015). The
/// bar never read the Help placements, so Send Feedback, Documentation and
/// the rest were in no menu, and the app menu listed About cmux twice.
@MainActor @Suite struct MainMenuPlacementTests {
    /// The action ids of every registry item anywhere under `menu`.
    static func actionIDs(in menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            var ids = (item.representedObject as? String).map { [$0] } ?? []
            if let submenu = item.submenu { ids += actionIDs(in: submenu) }
            return ids
        }
    }

    static func topMenu(_ placement: ActionMainMenu, in bar: NSMenu) -> NSMenu? {
        // macOS finds the Help menu through `NSApp.helpMenu` (its search field).
        if placement == .help {
            return bar.items.compactMap(\.submenu).first { $0 === NSApp.helpMenu }
        }
        if placement == .app { return bar.items.first?.submenu }
        let title: String? = switch placement {
        case .file: Strings.menuFile
        case .edit: Strings.menuEdit
        case .view: Strings.menuView
        case .server: Strings.menuServer
        case .window: Strings.menuWindow
        case .app, .help: nil
        }
        return bar.items.first { $0.title == title }?.submenu
    }

    @Test func compactMainMenuPlacementsStayInTheirTopMenu() {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let bar = MainMenu.make(registry: registry)
        var missing: [String] = []
        for (placement, ids) in MainMenu.compactActionIDs {
            guard let menu = Self.topMenu(placement, in: bar) else {
                missing.append("no \(placement) menu")
                continue
            }
            let shown = Set(Self.actionIDs(in: menu))
            for id in ids where !shown.contains(id.rawValue) {
                missing.append("\(id) not in the \(placement) menu")
            }
        }
        #expect(missing.isEmpty, "\(missing.count) compact placements missing:\n\(missing.joined(separator: "\n"))")
    }

    @Test func removedMainMenuActionsResolveFromPaletteSearch() {
        let registry = ActionRegistry.standard()
        // Give the provider every catalog fact so target-sensitive actions are included in
        // this catalog-level reachability check; runtime palette filtering still follows focus.
        registry.context = registry.descriptors.reduce(into: ActionContext()) { $0.formUnion($1.requires) }
        let items = RegistryPaletteProvider(registry: registry, includeUnbound: true).makeItems()
        let actionIDs = Set(items.compactMap(\.actionID))
        for id in MainMenu.removedMainMenuActionIDs {
            #expect(actionIDs.contains(id), "removed menu action \(id) is not palette-searchable")
        }
    }

    @Test func compactMenuCountsMatchAudit() {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let bar = MainMenu.make(registry: registry)
        // The audit counts the rows a menu shows. An alternate (Edit's Opt-Shift-Cmd-V Paste and
        // Match Style, #27619) takes its primary's row while Option is held, so it adds none.
        let counts = ActionMainMenu.allCases.reduce(into: [ActionMainMenu: Int]()) { result, menu in
            result[menu] = Self.topMenu(menu, in: bar)?.items.filter { !$0.isSeparatorItem && !$0.isAlternate }.count ?? 0
        }
        // Install an Earlier Nightly… (Leo 2026-11-02); Customize… beside Settings… (#43304, Leo 2026-11-15); one Quit
        // (CMUX-630, Leo 2026-11-15); Set Up cmux… (#46793, Leo 2026-11-18).
        #expect(counts[.app] == 11)
        #expect(counts[.file] == 16) // Screen Sharing, beside Connect to Machine… and Add Device…
        #expect(counts[.edit] == 7)
        #expect(counts[.view] == 10) // the right sidebar and Feed rows left with #41025
        #expect(counts[.server] == 2)
        #expect(counts[.window] == 13) // Merge All Windows (Leo 2026-10-29); New / Previous / Next Space (2026-11-15)
        #expect(counts[.help] == 5)
    }

    /// The space keys show where a person looks for them (Lawrence, Nov 15: "sidebar needs keyboard shortcuts
    /// for making new spaces"): Window lists New Space, Previous Space and Next Space with their keys,
    /// Ctrl-Opt-Cmd-N, -H and -L. The compact bar had left every space action out.
    @Test func windowMenuShowsTheSpaceKeys() throws {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let window = try #require(Self.topMenu(.window, in: MainMenu.make(registry: registry)))
        for (id, key) in [("space.new", "n"), ("space.previous", "h"), ("space.next", "l")] {
            let row = try #require(window.items.first { $0.representedObject as? String == id }, "\(id) not in Window")
            #expect(row.keyEquivalent == key, "\(id): \(row.keyEquivalent)")
            #expect(row.keyEquivalentModifierMask.intersection([.control, .option, .shift, .command]) == [.control, .option, .command], "\(id)")
        }
    }

    /// One Quit (CMUX-630, Leo 2026-11-15: "we should just have the one quit and it's the same quit when i right
    /// click the icon in the dock"): the cmux menu ends with Quit cmux (Cmd-Q) and no other quit; the quits that end
    /// the sessions stay command palette rows.
    @Test func appMenuHasOneQuit() throws {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let app = try #require(MainMenu.make(registry: registry).items.first?.submenu)
        let quits = app.items.filter { ($0.representedObject as? String)?.hasPrefix("quit") == true }
        #expect(quits.map { $0.representedObject as? String } == ["quit"], "quit rows: \(app.items.map(\.title))")
        #expect(app.items.last?.representedObject as? String == "quit")
        #expect(quits.first?.keyEquivalent == "q")
        for id: ActionID in ["quitEndSessions", "quitEndEverything"] {
            #expect(MainMenu.removedMainMenuActionIDs.contains(id), "\(id) is not a palette-only row")
        }
    }

    @Test func appMenuStartsWithOneAbout() throws {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let app = try #require(MainMenu.make(registry: registry).items.first?.submenu)
        let about = try #require(registry.title(for: "about"))
        #expect(app.items.filter { $0.title == about }.count == 1, "About rows: \(app.items.map(\.title))")
        #expect(app.items.first?.representedObject as? String == "about", "first row: \(app.items.first?.title ?? "none")")
    }
}
