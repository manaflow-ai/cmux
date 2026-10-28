import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch's action bindings and menu bar are the critical `AppActions.bind` and
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

    /// The design's key-equivalent test: right after `MainMenu.install` returns, before any frame, each
    /// shortcut of a menu-bar action, pressed as AppKit delivers it, resolves through `NSApp.mainMenu` to
    /// that action's item. The expected actions come from the placement table, not from the menu, so a
    /// submenu filled later (or not at all) fails here. Every keyed item is retargeted at a recorder, so the
    /// check reads which item the key found and runs no real handler (Quit, Close Window).
    @Test func everyMenuShortcutFiresItsItemBeforeTheFirstFrame() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let s = StartupTestScheduler()
        AppActions.bindAtLaunch(services, on: s.startup)
        MainMenu.install(registry: services.registry, blocking: services.blocking, on: s.startup)
        let menu = try #require(NSApp.mainMenu)
        let recorder = KeyEquivalentRecorder()
        for item in Self.items(in: menu) where !item.keyEquivalent.isEmpty {
            (item.target, item.action) = (recorder, #selector(KeyEquivalentRecorder.fire(_:)))
        }
        let registry = services.registry
        var placed = MainMenu.compactActionIDs.flatMap { placement, ids in ids.filter { registry.descriptor(for: $0)?.mainMenu == placement } }
        placed.append("zoomWindow")
        var idsByShortcut: [Shortcut: Set<String>] = [:]
        for id in placed where registry.descriptor(for: id)?.shortcutFamily == nil {
            guard let shortcut = registry.effectiveShortcut(for: id), Self.characters(of: shortcut) != nil else { continue }
            idsByShortcut[shortcut, default: []].insert(registry.canonicalID(for: id).rawValue)
        }
        #expect(!idsByShortcut.isEmpty, "the menu bar places actions with shortcuts")
        for (shortcut, ids) in idsByShortcut {
            let characters = try #require(Self.characters(of: shortcut))
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.modifiers,
                                                      timestamp: 1000, windowNumber: 0, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
            recorder.fired = nil
            let handled = menu.performKeyEquivalent(with: event)
            let firedID = recorder.fired?.identifier?.rawValue.replacingOccurrences(of: "cmux.action.", with: "")
            #expect(handled && firedID.map { ids.contains($0) } == true,
                    "\(ids.sorted()) (\(shortcut.key), \(shortcut.modifiers.rawValue)) fired \(firedID ?? "nothing")")
        }
    }

    /// Row O13's budget: `MainMenu.make` stays whole and critical only while it builds in < 2 ms (p95);
    /// over that, 030's deferral (top-level items critical, submenus afterFirstFrame) is due. An optimized
    /// build (`swift test -c release`) fails over budget; every build prints the cold run and p50/p95.
    @Test func theMenuBarBuildsWithinItsTwoMillisecondBudget() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu, previousHelp = NSApp.helpMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindows
            NSApp.helpMenu = previousHelp
        }
        AppActions.bind(services)
        let clock = ContinuousClock()
        let cold = clock.measure { _ = MainMenu.make(registry: services.registry, blocking: services.blocking) }
        let warm = (0..<40).map { _ in clock.measure { _ = MainMenu.make(registry: services.registry, blocking: services.blocking) } }.sorted()
        let p50 = warm[warm.count / 2], p95 = warm[warm.count * 95 / 100]
        print("MainMenu.make cold \(cold) p50 \(p50) p95 \(p95)")
        #if !DEBUG
        #expect(p95 < .milliseconds(2), "MainMenu.make p95 \(p95) (p50 \(p50), cold \(cold)) is over row O13's 2 ms")
        #endif
    }

    @Test func everyTabPaneScreenAndTerminalActionHasAHandler() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palettes.bindRegistryActions()
        let missing = services.registry.unboundActionIDs(in: HandlerCoverage.categories)
        #expect(missing.isEmpty, "unbound: \(missing.map(\.rawValue).joined(separator: ", "))")
    }

    /// The characters a key-down of `shortcut` carries: shift capitalizes a letter and leaves a function
    /// key (arrows, F-keys) as it is. A shifted symbol (Cmd-Shift-[ arrives as `{`) depends on the layout,
    /// so it is not pressed here.
    private static func characters(of shortcut: Shortcut) -> String? {
        guard shortcut.modifiers.contains(.shift) else { return shortcut.key }
        if shortcut.key.allSatisfy(\.isLetter) { return shortcut.key.uppercased() }
        let isFunctionKey = shortcut.key.unicodeScalars.allSatisfy { (0xF700...0xF8FF).contains($0.value) }
        return isFunctionKey ? shortcut.key : nil
    }

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { items(in: $0) } ?? []) }
    }
}

/// The target every keyed menu item is pointed at in the key-equivalent test: it records the item a key
/// equivalent resolved to and runs nothing.
@MainActor private final class KeyEquivalentRecorder: NSObject, NSMenuItemValidation {
    var fired: NSMenuItem?

    @objc func fire(_ sender: NSMenuItem) { fired = sender }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}
