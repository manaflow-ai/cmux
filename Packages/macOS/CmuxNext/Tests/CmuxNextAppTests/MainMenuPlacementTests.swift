import AppKit
import CmuxNextActions
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
        case .debug: Strings.menuDebug
        case .app, .help: nil
        }
        return bar.items.first { $0.title == title }?.submenu
    }

    @Test func everyMainMenuPlacementIsInItsTopMenu() {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let bar = MainMenu.make(registry: registry)
        var missing: [String] = []
        for descriptor in registry.descriptors {
            guard let placement = descriptor.mainMenu else { continue }
            if placement == .debug, !DevTools.isEnabled { continue }
            // Edit placements stay out of the bar until their key equivalents can't take keys
            // from a user's Ghostty keybinds or a panel (cmuxterm-hq#2015 C11).
            if placement == .edit { continue }
            guard let menu = Self.topMenu(placement, in: bar) else {
                missing.append("\(descriptor.id.rawValue): no \(placement) menu")
                continue
            }
            if !Self.actionIDs(in: menu).contains(descriptor.id.rawValue) {
                missing.append("\(descriptor.id.rawValue) not in the \(placement) menu")
            }
        }
        #expect(missing.isEmpty, "\(missing.count) placements not in the menu bar:\n\(missing.joined(separator: "\n"))")
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
