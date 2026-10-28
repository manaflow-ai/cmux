import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// The wrong-window error class (multiwindow.md, Lawrence 2026-10-28: "we also have a lot of bugs when we
/// have new windows. keyboard shortcuts dont work, and clicking on home/workspaces might bring me to the
/// wrong window. we need to completely eliminate this error class").
///
/// Three windows; the person is in window 2. Window 1 opened first (the launch window), window 3 last.
/// Every action of the catalog, from every entrypoint, acts in window 2 only:
/// - at once, while AppKit's key record still names another window (a stale record: the app activating
///   after Cmd-Tab, a key change in flight);
/// - and in the work the run starts, after the person has moved on to window 3 (a daemon reply, a page
///   that answers later): the run's window was decided when the input came, never read again later;
/// - with no key window at all (the CLI from another app), and after the window the person used last
///   closed: the window the person used before it, never the first window opened.
/// Each action is bound to a probe here, so the property covers the whole catalog's dispatch; the
/// handlers' own behavior in that window is covered by the Home cases below and the oracle journeys.
@MainActor @Suite(.serialized) struct MultiWindowActionTargetTests {
    /// The windows probe runs acted in: at once and in a task the run started.
    @MainActor final class Probe {
        var now: [ActionID: String] = [:]
        var later: [ActionID: String] = [:]
        var pending = 0
        var services: AppServices?

        func reset() { now = [:]; later = [:] }

        /// The handler every catalog action gets: it records the window its run acts in, then again from a
        /// task it starts, after the test moved the person to another window.
        func bind(_ registry: ActionRegistry) -> [ActionID] {
            ActionCatalog.all.compactMap { descriptor in
                let id = descriptor.id
                let bound = registry.bind(id, invoke: { [weak self] _ in
                    guard let self else { return }
                    now[id] = services?.windows.active?.state.id ?? "none"
                    pending += 1
                    // task-owner: the probe's own continuation, awaited by `drain`
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        guard let self else { return }
                        later[id] = services?.windows.active?.state.id ?? "none"
                        pending -= 1
                    }
                })
                return bound ? id : nil
            }
        }

        func drain() async {
            for _ in 0..<2000 where pending > 0 { await Task.yield() }
        }
    }

    private struct World {
        let services: AppServices
        let windows: [WindowController]
        let probe: Probe
        let ids: [ActionID]

        var w1: WindowController { windows[0] }
        var w2: WindowController { windows[1] }
        var w3: WindowController { windows[2] }

        func name(_ id: String?) -> String {
            guard let id else { return "no window" }
            if let index = windows.firstIndex(where: { $0.state.id == id }) { return "window \(index + 1)" }
            return id == "none" ? "no window" : "another window (\(id.prefix(8)))"
        }

        /// The person clicks into `controller`: AppKit makes it key, and the window records it.
        func personMoves(to controller: WindowController) {
            let shell = controller.window
            services.keyWindowSource = { shell }
            services.windows.didActivate(controller)
        }

        func close() {
            for controller in services.windows.controllers { controller.window?.close() }
        }
    }

    /// Windows 1, 2 and 3, opened in that order; the person used 1, then 3, then 2. Every catalog action
    /// is bound to the probe.
    private static func world() throws -> World {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let windows = try ["mwt-1", "mwt-2", "mwt-3"].map { workspace in
            try #require(services.windows.openWindow(workspaces: [workspace]))
        }
        for index in [0, 2, 1] { services.windows.didActivate(windows[index]) }
        let probe = Probe()
        probe.services = services
        let ids = probe.bind(services.registry)
        try #require(ids.count > 300, "only \(ids.count) catalog actions bound")
        return World(services: services, windows: windows, probe: probe, ids: ids)
    }

    /// An invocation every gate lets through: every context fact, every required argument, confirmed.
    private static func invocation(_ id: ActionID, origin: ActionOrigin, registry: ActionRegistry) -> ActionInvocation {
        var arguments: [String: ActionValue] = [ActionArgument.confirmName: .bool(true)]
        for argument in registry.descriptor(for: id)?.arguments ?? [] where argument.isRequired {
            arguments[argument.name] = .string("mwt")
        }
        var invocation = ActionInvocation(arguments: arguments, origin: origin)
        invocation.keyContext = ActionContext(rawValue: .max)
        return invocation
    }

    /// Runs every bound action through `entry` (the person is in window 2 when it starts), moves the person
    /// to window 3, waits for the runs' tasks, and lists each action whose run acted elsewhere than
    /// `expected`, at once and later.
    private static func check(_ world: World, entry: String, expected: WindowController,
                              before: () -> Void = {}, run: (ActionID) -> Void) async {
        var wrongNow: [String] = [], wrongLater: [String] = [], ran = 0
        for id in world.ids {
            world.probe.reset()
            before()
            run(id)
            guard world.probe.now[id] != nil else { continue }
            ran += 1
            world.personMoves(to: world.w3)
            await world.probe.drain()
            #expect(world.probe.pending == 0, "\(entry): \(id.rawValue)'s task never ran")
            if world.probe.now[id] != expected.state.id { wrongNow.append("\(id.rawValue) -> \(world.name(world.probe.now[id]))") }
            if let later = world.probe.later[id], later != expected.state.id { wrongLater.append("\(id.rawValue) -> \(world.name(later))") }
        }
        #expect(ran > world.ids.count / 2, "\(entry): only \(ran) of \(world.ids.count) actions ran")
        #expect(wrongNow.isEmpty, "\(entry): \(wrongNow.count) of \(ran) actions acted in another window at once: \(wrongNow.prefix(12))")
        #expect(wrongLater.isEmpty,
                "\(entry): \(wrongLater.count) of \(ran) actions' work landed in another window after the person moved on: \(wrongLater.prefix(12))")
    }

    // MARK: Every entrypoint, the whole catalog

    /// A key or a click in window 2 while AppKit's key record still names window 3.
    @Test func aKeyOrClickInWindowTwoActsInWindowTwo() async throws {
        let world = try Self.world()
        defer { world.close() }
        let shell2 = try #require(world.w2.window), shell3 = world.w3.window
        await Self.check(world, entry: "key or click", expected: world.w2, before: {
            world.services.windows.didActivate(world.w2)
            world.services.keyWindowSource = { shell3 }
        }) { id in
            let registry = world.services.registry
            world.services.windows.dispatching(eventFrom: shell2) {
                _ = registry.perform(id, invocation: Self.invocation(id, origin: .user, registry: registry))
            }
        }
    }

    /// Every default shortcut, through the key router, typed into window 2 (the newest window the person
    /// uses), runs what it runs in window 1, and acts in window 2.
    @Test func everyShortcutInTheNewWindowRunsAndActsThere() async throws {
        let world = try Self.world()
        defer { world.close() }
        var inFirst: Set<ActionID> = [], inNew: Set<ActionID> = [], wrong: [String] = []
        // Each key its own timestamp, as real keys have: the router never decides one key-down twice (DecidedKeyEvents).
        var stamp = 1000.0
        for descriptor in ActionCatalog.all {
            guard let shortcut = descriptor.defaultShortcut else { continue }
            for (index, controller) in [world.w1, world.w2].enumerated() {
                guard let shell = controller.window else { continue }
                world.probe.reset()
                world.personMoves(to: controller)
                if index == 1 { world.services.keyWindowSource = { [shell3 = world.w3.window] in shell3 } }
                let press = DebugKey.keyPress(shortcut.key, modifiers: Self.modifierNames(shortcut.modifiers))
                stamp += 1
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: press.flags, timestamp: stamp,
                                                   windowNumber: shell.windowNumber, context: nil, characters: press.characters,
                                                   charactersIgnoringModifiers: press.characters, isARepeat: false, keyCode: press.keyCode) else { continue }
                // No event-origin scope: the key router itself names the window the key was typed in.
                _ = world.services.keyRouter.dispatchingSynthetic(event) { world.services.routeKeyDown(event, shell) }
                if index == 1 { world.personMoves(to: world.w3) }
                await world.probe.drain()
                for (id, window) in world.probe.now {
                    if index == 0 { inFirst.insert(id) } else { inNew.insert(id) }
                    if window != controller.state.id { wrong.append("\(shortcut.displayString) \(id.rawValue) -> \(world.name(window))") }
                    if let later = world.probe.later[id], later != controller.state.id {
                        wrong.append("\(shortcut.displayString) \(id.rawValue) later -> \(world.name(later))")
                    }
                }
            }
        }
        #expect(!inFirst.isEmpty, "no shortcut ran in window 1")
        let missing = inFirst.subtracting(inNew).map(\.rawValue).sorted()
        #expect(missing.isEmpty, "\(missing.count) shortcuts run in window 1 but not in the new window: \(missing.prefix(12))")
        #expect(wrong.isEmpty, "\(wrong.count) shortcuts acted in another window than the one they were typed in: \(wrong.prefix(12))")
    }

    /// A menu item: no event window; window 2 is key when the menu runs it.
    @Test func aMenuItemActsInTheKeyWindowOfItsEvent() async throws {
        let world = try Self.world()
        defer { world.close() }
        await Self.check(world, entry: "menu", expected: world.w2, before: { world.personMoves(to: world.w2) }) { id in
            let registry = world.services.registry
            _ = registry.perform(id, invocation: Self.invocation(id, origin: .user, registry: registry))
        }
    }

    /// A palette row: the key is typed into the palette's panel over window 2.
    @Test func aPaletteRowActsInTheWindowUnderThePalette() async throws {
        let world = try Self.world()
        defer { world.close() }
        let shell2 = try #require(world.w2.window)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        shell2.addChildWindow(panel, ordered: .above)
        defer { shell2.removeChildWindow(panel); panel.close() }
        await Self.check(world, entry: "palette", expected: world.w2, before: {
            world.services.windows.didActivate(world.w2)
            world.services.keyWindowSource = { panel }
        }) { id in
            let registry = world.services.registry
            world.services.windows.dispatching(eventFrom: panel) {
                _ = registry.perform(id, invocation: Self.invocation(id, origin: .user, registry: registry))
            }
        }
    }

    /// The CLI with no `--window`, from another app (no cmux window is key): the window the person used last.
    @Test func theCLIWithNoWindowActsInThePersonsLastWindow() async throws {
        let world = try Self.world()
        defer { world.close() }
        await Self.check(world, entry: "cli", expected: world.w2, before: {
            world.services.windows.didActivate(world.w2)
            world.services.keyWindowSource = { nil }
        }) { id in
            let registry = world.services.registry
            _ = registry.perform(id, invocation: Self.invocation(id, origin: .cli, registry: registry))
        }
    }

    /// The person used window 2, then window 3, then closed window 3 with cmux in the background: the CLI
    /// acts in window 2 (the window the person used before), never window 1 (the first window opened).
    @Test func afterThePersonsWindowClosesTheCLIActsInTheWindowBefore() async throws {
        let world = try Self.world()
        defer { world.close() }
        world.services.keyWindowSource = { nil }
        world.services.windows.didActivate(world.w2)
        world.services.windows.didActivate(world.w3)
        world.w3.window?.close()
        try #require(!world.services.windows.controllers.contains { $0 === world.w3 }, "window 3 did not close")
        var wrong: [String] = [], ran = 0
        for id in world.ids {
            world.probe.reset()
            let registry = world.services.registry
            _ = registry.perform(id, invocation: Self.invocation(id, origin: .cli, registry: registry))
            await world.probe.drain()
            guard let window = world.probe.now[id] else { continue }
            ran += 1
            if window != world.w2.state.id { wrong.append("\(id.rawValue) -> \(world.name(window))") }
        }
        #expect(ran > world.ids.count / 2, "only \(ran) of \(world.ids.count) actions ran")
        #expect(wrong.isEmpty, "\(wrong.count) of \(ran) CLI runs acted in another window than the person's last one: \(wrong.prefix(12))")
    }

    /// A run's own code brings window 3 forward (New Window, Select Next Window, Move to New Window):
    /// the run's later work acts in window 3, and window 3 is the window the person is in (it publishes
    /// the app's focus context), as an event's dispatch follows the window its action brought forward.
    @Test func aRunFollowsTheWindowItsOwnCodeBroughtForward() async throws {
        let world = try Self.world()
        defer { world.close() }
        let shell2 = try #require(world.w2.window)
        let windows = world.services.windows
        @MainActor final class Seen { var after: String?, person: String? }
        let seen = Seen()
        let registry = world.services.registry, services = world.services, w3 = world.w3
        registry.bind("zoomWindow", invoke: { _ in
            // task-owner: the test's own continuation, awaited below
            Task { @MainActor in
                await Task.yield()
                // The run's code made window 3 key.
                let shell3 = w3.window
                services.keyWindowSource = { shell3 }
                services.windows.didActivate(w3)
                seen.after = windows.active?.state.id
                seen.person = windows.personWindow?.state.id
            }
        })
        world.services.keyWindowSource = { shell2 }
        windows.dispatching(eventFrom: shell2) { _ = registry.perform("zoomWindow", invocation: ActionInvocation(origin: .user)) }
        for _ in 0..<2000 where seen.after == nil { await Task.yield() }
        #expect(seen.after == world.w3.state.id, "the run's work after it brought window 3 forward acted in \(world.name(seen.after))")
        #expect(seen.person == world.w3.state.id, "the window the person is in is \(world.name(seen.person)), not window 3")
    }

    /// The same through the order record `WindowActivation.show` writes (`windowDidOrder(_:inFront:)`), before
    /// AppKit's key notice: the run's later work already acts in the window it brought forward.
    @Test func aRunFollowsTheWindowItOrderedInFront() async throws {
        let world = try Self.world()
        defer { world.close() }
        let shell2 = try #require(world.w2.window)
        @MainActor final class Seen { var after: String? }
        let seen = Seen()
        let registry = world.services.registry, services = world.services, w3 = world.w3
        registry.bind("zoomWindow", invoke: { _ in
            // task-owner: the test's own continuation, awaited below
            Task { @MainActor in
                await Task.yield()
                if let shell3 = w3.window { services.windows.windowDidOrder(shell3, inFront: true) }
                seen.after = services.windows.active?.state.id
            }
        })
        world.services.keyWindowSource = { shell2 }
        world.services.windows.dispatching(eventFrom: shell2) {
            _ = registry.perform("zoomWindow", invocation: ActionInvocation(origin: .user))
        }
        for _ in 0..<2000 where seen.after == nil { await Task.yield() }
        #expect(seen.after == world.w3.state.id, "the run's work after it ordered window 3 in acted in \(world.name(seen.after))")
    }

    // MARK: Home and the sidebar, real handlers

    private struct HomeWorld {
        let services: AppServices
        let w1: WindowController, w2: WindowController, w3: WindowController
        static let home = "mwh-home"

        func shown() -> [String?] { [w1, w2, w3].map(\.state.workspaceID) }
        /// What each window shows: "Home" for its Home (the home workspace, or its own Home page), else its workspace.
        func showing() -> [String] {
            [w1, w2, w3].map { window in
                window.state.page == .home || (window.state.page == nil && window.state.workspaceID == Self.home) ? "Home" : window.state.workspaceID ?? "nothing"
            }
        }
        func close() { for controller in services.windows.controllers { controller.window?.close() } }
    }

    /// The local store has the Home workspace; window 1 lists it (behind its own workspace), windows 2 and 3
    /// show their own. The app's real actions are bound.
    private static func homeWorld() throws -> HomeWorld {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-mwh","generation":"g1"}"#
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let keys = ["mwh-1", HomeWorld.home, "mwh-2", "mwh-3"]
        let workspaces = keys.enumerated().map { index, key in
            var workspace = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [])
            if key == HomeWorld.home { workspace.kind = "home" }
            return workspace
        }
        store.apply(snapshot: DaemonTree(registryID: "s-mwh", workspaces: workspaces))
        services.windows.ordersWindowsIn = false
        AppActions.bind(services)
        let w1 = try #require(services.windows.openWindow(workspaces: ["mwh-1", HomeWorld.home]))
        let w2 = try #require(services.windows.openWindow(workspaces: ["mwh-2"]))
        let w3 = try #require(services.windows.openWindow(workspaces: ["mwh-3"]))
        for controller in [w1, w3, w2] { services.windows.didActivate(controller) }
        try #require(services.home.homeWorkspace?.id == HomeWorld.home, "the store reported no Home workspace")
        try #require(w1.state.workspaceID == "mwh-1" && w2.state.workspaceID == "mwh-2" && w3.state.workspaceID == "mwh-3")
        return HomeWorld(services: services, w1: w1, w2: w2, w3: w3)
    }

    /// Home clicked in window 2's sidebar (AppKit's key record still names window 3): window 2 shows Home;
    /// window 1, which listed it, and window 3 keep what they show.
    @Test func homeClickedInWindowTwoShowsInWindowTwo() throws {
        let world = try Self.homeWorld()
        defer { world.close() }
        let shell2 = try #require(world.w2.window), shell3 = world.w3.window
        world.services.keyWindowSource = { shell3 }
        world.services.windows.dispatching(eventFrom: shell2) { world.w2.sidebar.activate(.builtIn(.home)) }
        #expect(world.showing() == ["mwh-1", "Home", "mwh-3"], "Home clicked in window 2: windows 1, 2, 3 show \(world.showing())")
        #expect(world.services.windows.registry.value.owner(of: HomeWorld.home) == world.w1.state.id, "Home moved out of window 1")
    }

    /// Home from its key or the menu while window 2 is key: the same.
    @Test func homeFromTheMenuInWindowTwoShowsInWindowTwo() throws {
        let world = try Self.homeWorld()
        defer { world.close() }
        let shell2 = world.w2.window
        world.services.keyWindowSource = { shell2 }
        _ = world.services.registry.perform("home.show", invocation: ActionInvocation(origin: .user))
        #expect(world.showing() == ["mwh-1", "Home", "mwh-3"], "Home from the menu in window 2: windows 1, 2, 3 show \(world.showing())")
    }

    /// One Home per window (audit-findings-1 C: every window shows Home when it has nothing else; Home never
    /// closes). Window 1 shows only Home; Home clicked in window 2: window 2 shows Home, window 1 still shows
    /// Home, and the key window does not change (no window comes forward, none closes).
    @Test func homeClickedInWindowTwoLeavesWindowOnesHome() throws {
        let world = try Self.homeWorld()
        defer { world.close() }
        let windows = world.services.windows
        _ = windows.moveWorkspaces(["mwh-1"], toWindow: world.w3.state.id, select: false)
        windows.show(workspaceID: HomeWorld.home, in: world.w1.state)
        let listed = windows.registry.members(of: world.w1.state.id)
        try #require(listed == [HomeWorld.home] && world.w1.state.workspaceID == HomeWorld.home, "window 1 lists \(listed)")
        let shell2 = try #require(world.w2.window), shell3 = world.w3.window
        world.services.keyWindowSource = { shell3 }  // a stale key record: window 3
        var ordered: [NSWindow] = []
        let previous = WindowActivation.didOrder
        WindowActivation.didOrder = { window, inFront in ordered.append(window); previous?(window, inFront) }
        defer { WindowActivation.didOrder = previous }
        windows.dispatching(eventFrom: shell2) { world.w2.sidebar.activate(.builtIn(.home)) }
        #expect(windows.controllers.contains { $0 === world.w1 }, "Home clicked in window 2 closed window 1")
        #expect(world.showing() == ["Home", "Home", "mwh-3"], "Home clicked in window 2: windows 1, 2, 3 show \(world.showing())")
        #expect(windows.registry.value.owner(of: HomeWorld.home) == world.w1.state.id, "Home moved out of window 1")
        #expect(ordered.isEmpty, "Home clicked in window 2 ordered \(ordered.count) window(s) in front")
        #expect(world.services.keyWindowSource() === shell3, "the key window changed")
    }

    /// A workspace row clicked in window 2's sidebar (the row of a workspace window 1 lists): window 2 shows
    /// it; windows 1 and 3 keep what they show.
    @Test func aWorkspaceRowClickedInWindowTwoShowsInWindowTwo() throws {
        let world = try Self.homeWorld()
        defer { world.close() }
        let shell2 = try #require(world.w2.window), shell3 = world.w3.window
        world.services.keyWindowSource = { shell3 }
        world.services.windows.dispatching(eventFrom: shell2) { world.w2.sidebar.handle(.select(SidebarWorkspaceID(HomeWorld.home))) }
        #expect(world.shown() == ["mwh-1", HomeWorld.home, "mwh-3"],
                "a row clicked in window 2: windows 1, 2, 3 show \(world.shown().map { $0 ?? "nothing" })")
    }

    private static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        [(NSEvent.ModifierFlags.command, "command"), (.shift, "shift"), (.option, "option"), (.control, "control")]
            .compactMap { flags.contains($0.0) ? $0.1 : nil }
    }
}
