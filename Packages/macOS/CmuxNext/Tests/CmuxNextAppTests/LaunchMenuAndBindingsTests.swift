import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// p08-startup-030: the launch's action bindings and menu bar are the critical `AppActions.bind` and
/// `MainMenu.make` steps (startup-DESIGN.md rows O11 and O13), each a startup task record with its run
/// time; the menu is whole when its step ends, so every key equivalent is there from the first frame;
/// and the handler coverage the Debug launch checks holds in every build (row O12).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchMenuAndBindingsTests {
    @Test func theBindingsAndTheMenuAreTimedCriticalStepsBeforeTheFirstFrame() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let s = StartupTestScheduler()
        AppActions.bindAtLaunch(services, on: s.startup)
        #expect(services.registry.isBound("quit"), "bound in the step's turn, before any frame")
        MainMenu.install(registry: services.registry, blocking: services.blocking, on: s.startup)
        let menu = NSApp.mainMenu
        #expect(menu != nil && menu !== previousMenu, "the menu bar is installed in the step's turn")
        let records = s.startup.log.records
        for name in ["AppActions.bind", "MainMenu.make"] {
            let record = records.first { $0.name.description == name }
            #expect(record?.priority == .critical, "\(name) is a critical step")
            #expect(record?.violation == nil, "\(name) is in the critical allowlist")
            #expect(record?.durationNanos != nil, "\(name) ran and its time is recorded")
        }
        // Not deferred: each top-level menu is filled, so a key equivalent finds its item at once.
        for item in menu?.items ?? [] {
            #expect(item.submenu?.items.isEmpty == false, "\(item.title) is filled at install")
        }
    }

    @Test func theInstalledMenuCarriesEveryShortcutOfItsActions() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let s = StartupTestScheduler()
        AppActions.bindAtLaunch(services, on: s.startup)
        MainMenu.install(registry: services.registry, blocking: services.blocking, on: s.startup)
        let menu = try #require(NSApp.mainMenu)
        let registry = services.registry
        var checked = 0
        for item in Self.items(in: menu) {
            guard let raw = item.identifier?.rawValue, raw.hasPrefix("cmux.action.") else { continue }
            let id = ActionID(String(raw.dropFirst("cmux.action.".count)))
            guard registry.descriptor(for: id)?.shortcutFamily == nil, let shortcut = registry.effectiveShortcut(for: id) else { continue }
            #expect(item.keyEquivalent == shortcut.key, "\(id.rawValue)'s menu item shows its key")
            #expect(item.keyEquivalentModifierMask == shortcut.modifiers, "\(id.rawValue)'s menu item shows its modifiers")
            checked += 1
        }
        #expect(checked > 0, "the menu bar has action items with shortcuts")
    }

    @Test func everyTabPaneScreenAndTerminalActionHasAHandler() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palettes.bindRegistryActions()
        let missing = services.registry.unboundActionIDs(in: HandlerCoverage.categories)
        #expect(missing.isEmpty, "unbound: \(missing.map(\.rawValue).joined(separator: ", "))")
    }

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
    }
}
