import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Keys typed into a terminal the person just opened go to it as soon as it has the keyboard, not at the creation's
/// reply or at the next key (first-seconds-evidence.md, Lawrence's optimized v2.2.3: 30 of 226 terminal keys waited
/// 250-1600 ms in `CreationInputCoordinator` and were sent again late). The new terminal's view sends them to the
/// daemon by the terminal id its create chose (cx-wb5.78), so nothing waits for the daemon. Chrome routes input to the
/// focused frame at once and never replays it late.
@MainActor @Suite(.serialized)
struct EarlyTerminalKeysTests {
    /// One workspace with one pane and one terminal tab.
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "early-ws"), name: "early", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "early-ws"), index: 0)])
        return tree
    }

    private static func key(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let window: NSWindow
        let paneKey: String
        let tab: String
        let entry: TerminalEntry
    }

    /// A window showing one terminal that has the focus; `body` runs with it.
    private static func withTerminal(_ body: (Harness) async throws -> Void) async throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["early-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        // The app's InputVerification.start launch post runs after the first frame, so after the launch window opened
        // and installed its focus settle observer: that window's settles must still reach the key router.
        services.input.start(services: services)
        let window = try #require(controller.window)
        let paneKey = try #require(store.workspaces.first?.screens.first?.panes.first?.id)
        try await PasswordManagerRouteTests.until({ controller.workspaceContent?.paneController(key: paneKey)?.currentContent != nil },
                                                  within: .seconds(10), report: { "the pane never showed its terminal" })
        let pane = try #require(controller.workspaceContent?.paneController(key: paneKey))
        guard case .terminal(let entry)? = pane.currentContent, let tab = pane.currentTabKey else {
            Issue.record("the pane shows no terminal")
            return
        }
        controller.focus.send(.focusPane(paneKey, source: .programmatic))
        try await PasswordManagerRouteTests.until({ controller.focus.state.resolved == .terminal(pane: paneKey, tab: tab) },
                                                  within: .seconds(5), report: { "focus never named the terminal" })

        try await body(Harness(services: services, controller: controller, window: window, paneKey: paneKey, tab: tab, entry: entry))
    }

    /// The new terminal's view is still being mounted (not in the window): it cannot take the keyboard. Returns how to
    /// mount it again. Focus still names it.
    private static func unmount(_ h: Harness) throws -> () -> Void {
        let surface = h.entry.session.surfaceView
        let parent = try #require(surface.superview, "the terminal's view is not in a view")
        surface.removeFromSuperview()
        return { parent.addSubview(surface) }
    }

    private static func held(_ h: Harness) -> String {
        "focus \(h.controller.focus.state.resolved), first responder \(String(describing: h.window.firstResponder.map { type(of: $0) })), "
            + "holding \(h.services.keyRouter.creationInputCoordinator.isHolding(in: h.window)), modes \(h.services.keyRouter.modes.active)"
    }

    /// The early view of a pending creation (here the pane's terminal stands in for it) gets the keyboard after a key
    /// was held: the next key runs the held key first, then goes on itself, with no reply (before, the held keys waited
    /// for the reply and were sent again with their old OS time). Green step 4f52ecc7 showed that the harness gives no
    /// focus settle after `makeFirstResponder`, so the test drives the key path, which the app takes when no settle comes.
    @Test func heldKeysGoToTheEarlyTerminalWhenItGetsTheKeyboard() async throws {
        try await Self.withTerminal { h in
            let (controller, window, tab, entry) = (h.controller, h.window, h.tab, h.entry)
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            let mount = try Self.unmount(h)
            _ = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation, earlyTab: tab, tab: tab),
                             "the creation opened no key hold")
            let typed = try Self.key("a", keyCode: 0, in: window)
            let held = router.interceptKeyDown(typed, in: window)
            #expect(held, "the key was not held while the new terminal could not take it: \(Self.held(h))")
            #expect(coordinator.heldCount(in: window) == 1)
            let before = coordinator.replayedCount

            // The view is mounted and has the keyboard: the next key runs the held one first, then goes on.
            mount()
            window.makeFirstResponder(entry.session.surfaceView)
            let next = router.interceptKeyDown(try Self.key("b", keyCode: 11, in: window), in: window)
            #expect(!next, "the key after the terminal took the keyboard waited: \(Self.held(h))")
            #expect(coordinator.replayedCount == before + 1, "the held key was dropped, not run into the new terminal")
            #expect(coordinator.heldCount(in: window) == 0)
            #expect(coordinator.isHolding(in: window), "the hold ended before its creation resolved")
        }
    }

    /// The same, through the focus settle the app gets (FocusCoordinator.settledObserver, wired by
    /// InputVerificationService to KeyRouter.focusDidSettle): the held key goes to the early terminal at the settle,
    /// with no later key (the coordinator's requirement: the settle path must have a test of its own, not only the bench).
    @Test func heldKeysGoToTheEarlyTerminalAtTheFocusSettle() async throws {
        try await Self.withTerminal { h in
            let (controller, window, tab, entry) = (h.controller, h.window, h.tab, h.entry)
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            let settle = try #require(controller.focus.settledObserver, "the window has no focus settle observer (the app's seam)")
            let mount = try Self.unmount(h)
            _ = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation, earlyTab: tab, tab: tab))
            #expect(router.interceptKeyDown(try Self.key("a", keyCode: 0, in: window), in: window),
                    "the key was not held while the new terminal could not take it: \(Self.held(h))")
            let before = coordinator.replayedCount

            mount()
            window.makeFirstResponder(entry.session.surfaceView)
            #expect(window.firstResponder === entry.session.surfaceView, "the test needs the terminal to have the keyboard")
            // The settle the app sends after its focus queue drained.
            settle(controller.focus.state)
            try await PasswordManagerRouteTests.until({ coordinator.heldCount(in: window) == 0 }, within: .seconds(2),
                                                      report: { "the held key still waits after the settle: \(coordinator.earlyDeliveryState(in: window)); \(Self.held(h))" })
            #expect(coordinator.replayedCount == before + 1, "the held key was dropped at the settle, not run into the new terminal")
            #expect(coordinator.isHolding(in: window), "the hold ended before its creation resolved")
        }
    }

    /// The early tab is focused, but another view (an agent's composer, Home's message box) has the keyboard: the held
    /// key stays held. Terminal input never goes anywhere but the new terminal (review of 107f5da1ac6: the early check
    /// let any non-terminal first responder take the held keys).
    @Test func heldKeysNeverGoToAnotherViewThatHasTheKeyboard() async throws {
        try await Self.withTerminal { h in
            let (controller, window, paneKey, tab) = (h.controller, h.window, h.paneKey, h.tab)
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            window.contentView?.addSubview(composer)
            defer { composer.removeFromSuperview() }
            let mount = try Self.unmount(h)
            defer { mount() }
            _ = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation, earlyTab: tab, tab: tab))
            let typed = try Self.key("a", keyCode: 0, in: window)
            let held = router.interceptKeyDown(typed, in: window)
            #expect(held, "the key was not held while the new terminal could not take it: \(Self.held(h))")
            let before = coordinator.replayedCount
            window.makeFirstResponder(composer)
            controller.focus.send(.contentPresented(pane: paneKey))
            try await Task.sleep(for: .milliseconds(200))
            // The next key comes while the composer has the keyboard: it waits too, and nothing held runs into the composer.
            let next = try Self.key("b", keyCode: 11, in: window)
            #expect(router.interceptKeyDown(next, in: window), "a key typed for the new terminal went on to another view: \(Self.held(h))")
            #expect(coordinator.replayedCount == before, "a key typed for the new terminal was run into another view: \(Self.held(h))")
            #expect(composer.string.isEmpty, "a key typed for the new terminal reached another text input")
        }
    }

    /// Cmd-W of the new terminal after focus landed on it (the expectation is gone): the keys typed for it go with it.
    /// Before, the close branch read only the focus expectation, so the hold force-ran them into whatever had the
    /// keyboard (the old terminal) before the close (review of a8acc611977, finding A).
    @Test func closingTheNewTerminalAfterFocusLandedDropsItsKeys() async throws {
        try await Self.withTerminal { h in
            let (controller, window, paneKey, tab) = (h.controller, h.window, h.paneKey, h.tab)
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            let mount = try Self.unmount(h)
            defer { mount() }
            _ = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation, earlyTab: tab, tab: tab))
            #expect(controller.focus.state.expectation == nil, "the test needs focus landed on the new terminal")
            #expect(controller.focus.state.resolved == .terminal(pane: paneKey, tab: tab), "focus left the new terminal: \(Self.held(h))")
            let typed = try Self.key("a", keyCode: 0, in: window)
            #expect(router.interceptKeyDown(typed, in: window), "the key was not held: \(Self.held(h))")
            let before = coordinator.replayedCount
            let close = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                      isARepeat: false, keyCode: 13))
            _ = router.interceptKeyDown(close, in: window)
            #expect(coordinator.replayedCount == before, "a key typed for the closed terminal was run into another view")
            #expect(coordinator.heldCount(in: window) == 0, "the keys typed for the closed terminal still wait")
        }
    }

    /// The creation replied, focus landed and the new terminal has the keyboard, but no focus settle came after that: the
    /// next key goes straight to the terminal, it never waits for the hold's 2 s bound (first-keys-proof item 2, step
    /// db4c7066: keys typed after the reply waited 2 s because only a settle ended the hold).
    @Test func aKeyAfterTheReplyGoesOnWhenTheNewTerminalHasTheKeyboard() async throws {
        try await Self.withTerminal { h in
            let (controller, window) = (h.controller, h.window)
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            let ticket = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation))
            coordinator.resolve(ticket, landed: true, in: window) // its flush runs in a later turn
            #expect(window.firstResponder === h.entry.session.surfaceView, "the test needs the terminal to have the keyboard")
            let typed = try Self.key("a", keyCode: 0, in: window)
            let held = router.interceptKeyDown(typed, in: window)
            #expect(!held, "a key typed into the new terminal that has the keyboard waited in the hold: \(Self.held(h))")
            #expect(!coordinator.isHolding(in: window), "the hold outlived the moment its terminal took the keyboard")
        }
    }

    /// Keys held before the reply run first, in order, then the key after it goes on, when the new terminal has the
    /// keyboard (independent review of 995d00522ac, finding 1: the replay path was not exercised).
    @Test func heldKeysRunBeforeTheKeyThatEndsTheHold() async throws {
        try await Self.withTerminal { h in
            let (controller, window) = (h.controller, h.window)
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            let ticket = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation))
            for (letter, code) in [("a", UInt16(0)), ("b", UInt16(11))] {
                #expect(router.interceptKeyDown(try Self.key(letter, keyCode: code, in: window), in: window),
                        "a key before the reply was not held: \(Self.held(h))")
            }
            let before = coordinator.replayedCount
            coordinator.resolve(ticket, landed: true, in: window)
            let held = router.interceptKeyDown(try Self.key("c", keyCode: 8, in: window), in: window)
            #expect(!held, "the key after the reply waited: \(Self.held(h))")
            #expect(coordinator.replayedCount == before + 2, "the two held keys did not run first")
            #expect(!coordinator.isHolding(in: window))
        }
    }

    /// A resolved hold whose new terminal does not have the keyboard yet (its view is still being mounted) keeps the key:
    /// ending at the key is only for a terminal that can take it (review of 995d00522ac, finding 1, negative case).
    @Test func aResolvedHoldKeepsTheKeyWhileTheTerminalCannotTakeIt() async throws {
        try await Self.withTerminal { h in
            let (controller, window) = (h.controller, h.window)
            let router = h.services.keyRouter
            let coordinator = router.creationInputCoordinator
            let mount = try Self.unmount(h)
            defer { mount() }
            let ticket = try #require(coordinator.begin(in: window, generation: controller.focus.state.generation))
            coordinator.resolve(ticket, landed: true, in: window)
            let before = coordinator.replayedCount
            let held = router.interceptKeyDown(try Self.key("a", keyCode: 0, in: window), in: window)
            #expect(held, "a key went on while the new terminal could not take it: \(Self.held(h))")
            #expect(coordinator.replayedCount == before)
            #expect(coordinator.isHolding(in: window))
        }
    }
}
