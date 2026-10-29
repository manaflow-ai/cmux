import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextLaunch
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// Keys while a window shows its launch picture. A key changes only the model in its turn: an
/// action runs (a Command chord, a Control chord, a chord's leader and the key after it), a key the window cannot
/// decide yet waits whole and goes through the router again once it can, and typing for a terminal that is still a
/// picture waits in that terminal's stand-in buffer, which raises the pane's slice to the next frame and reaches the
/// terminal exactly once, in order, when it is live. Clicks: `LaunchPictureClickTests`.
@MainActor @Suite(.serialized)
struct LaunchPictureInputTests {
    // MARK: Keys, through the router

    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let shell: NSWindow
        var router: KeyRouter { services.keyRouter }
        var keys: LaunchPictureKeys { services.keyRouter.launchPictureKeys }
        var target: LaunchPictureKeys.Target { .init(window: controller.state.id, pane: "picture-pane", tab: "picture-tab") }
        func close() { for controller in services.windows.controllers { controller.window?.close() } }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["picture-workspace"]))
        let shell = try #require(controller.window)
        try focusTerminal(of: controller, workspace: "picture-workspace", pane: "picture-pane", tab: "picture-tab")
        return Harness(services: services, controller: controller, shell: shell)
    }

    private static func focusTerminal(of controller: WindowController, workspace: String, pane: String, tab: String) throws {
        controller.focus.send(.topology(FocusTopology(workspace: workspace, panes: [
            .init(id: pane, tabs: [.init(id: tab, kind: .terminal)], selected: tab),
        ])))
        controller.focus.send(.focusPane(pane, source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: pane, tab: tab))
    }

    private static var timestamp: TimeInterval = 12_000

    private static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                            ignoringModifiers: String? = nil, window: Int = 0) throws -> NSEvent {
        timestamp += 0.01
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                             windowNumber: window, context: nil, characters: characters,
                                             charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false,
                                             keyCode: keyCode))
    }

    /// The router's decision for `event` in `window`, dispatched as `sendEvent` does: whether it consumed the key.
    private static func dispatch(_ event: NSEvent, in window: NSWindow, router: KeyRouter) -> Bool {
        router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
    }

    /// Typing while the focused terminal is a picture waits for it: the router takes each key, raises the pane's
    /// slice once (not per key, and only that pane), and turns its mode on only while the picture shows.
    @Test func typingForATerminalStillAPictureWaitsAndRaisesOnlyItsPane() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        var raised: [String?] = []
        #expect(!harness.router.modes.contains(.launchPicture))
        harness.keys.begin(window: harness.target.window, shell: harness.shell) { raised.append($0) }
        #expect(harness.router.modes.contains(.launchPicture), "the picture phase did not turn the router's mode on")

        for (letter, code) in [("l", UInt16(37)), ("s", 1), ("\r", 36)] {
            let event = try Self.key(letter, keyCode: code, window: harness.shell.windowNumber)
            #expect(Self.dispatch(event, in: harness.shell, router: harness.router),
                    "the key for a terminal still a picture went on to a view that cannot take it")
        }
        #expect(harness.keys.isHolding(harness.target))
        #expect(raised == ["picture-pane"], "raised \(raised): the slice is raised once, for the focused pane only")
    }

    /// A Command chord no action takes is a key equivalent, not typing: it never waits behind the picture.
    @Test func aCommandChordIsNeverHeldForThePicture() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.keys.begin(window: harness.target.window, shell: harness.shell) { _ in }
        let chord = try Self.key("k", keyCode: 40, modifiers: .command, window: harness.shell.windowNumber)
        #expect(!harness.keys.holdsForTerminal(chord, in: harness.shell, router: harness.router))
        #expect(!harness.keys.isHolding(harness.target))
    }

    /// A Control leader bound to an action arms its chord in the picture phase and the key after it runs the action,
    /// exactly as with no picture: neither waits as terminal input. An unbound Control key is typing: it waits.
    @Test func aControlLeaderChordRunsItsActionInThePicturePhase() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let registry = harness.services.registry
        var runs = 0
        registry.unbind("toggleSidebar")
        registry.bindEffect("toggleSidebar") { _ in
            runs += 1
            return .done
        }
        KeyBindingLoader(registry).load(KeyBindingLayers(user: [
            KeyBinding(keys: [Shortcut("b", modifiers: [.control]), Shortcut("c", modifiers: [])], command: "toggleSidebar", source: .user),
        ]))
        harness.keys.begin(window: harness.target.window, shell: harness.shell) { _ in }

        let leader = try Self.key("\u{02}", keyCode: 11, modifiers: .control, ignoringModifiers: "b", window: harness.shell.windowNumber)
        #expect(Self.dispatch(leader, in: harness.shell, router: harness.router), "the Control leader went on to the terminal")
        #expect(harness.router.chords.isPending, "the Control leader did not arm its chord in the picture phase")
        let next = try Self.key("c", keyCode: 8, window: harness.shell.windowNumber)
        #expect(Self.dispatch(next, in: harness.shell, router: harness.router))
        #expect(runs == 1, "the chord's action ran \(runs) times")
        #expect(!harness.keys.isHolding(harness.target), "a key of the chord waited as terminal input")

        let unbound = try Self.key("\u{03}", keyCode: 8, modifiers: .control, ignoringModifiers: "c", window: harness.shell.windowNumber)
        #expect(Self.dispatch(unbound, in: harness.shell, router: harness.router))
        #expect(harness.keys.isHolding(harness.target), "an unbound Control key is the terminal's: it waits for it")
    }

    /// Outside the picture phase the router never asks the stand-in buffer (normal mode stays normal).
    @Test func noPictureNoHold() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        #expect(harness.router.modes.isNormal)
        let event = try Self.key("a", keyCode: 0, window: harness.shell.windowNumber)
        #expect(!harness.keys.holdsForTerminal(event, in: harness.shell, router: harness.router))
        #expect(!harness.keys.holdsUndecided(event, in: harness.shell, router: harness.router))
    }

    /// Keys typed in the picture's window before it has a controller wait whole, in order, and raise the window's
    /// build; once the controller exists and its focus resolved, they go through the router again and land in the
    /// focused terminal's stand-in buffer. A key typed meanwhile goes behind them.
    @Test func keysTypedBeforeTheWindowHasAControllerWaitForIt() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let router = services.keyRouter, keys = router.launchPictureKeys
        let id = "picture-window-before-controller"
        let picture = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        picture.isReleasedWhenClosed = false
        defer { picture.close() }
        var raised: [String?] = []
        keys.begin(window: id, shell: picture) { raised.append($0) }

        let burst = try [("e", UInt16(14)), ("c", 8), ("h", 4)].map { try Self.key($0.0, keyCode: $0.1, window: picture.windowNumber) }
        for event in burst { #expect(Self.dispatch(event, in: picture, router: router), "a key typed before the controller was lost") }
        #expect(keys.isHoldingUndecided(window: id))
        #expect(raised == [nil], "the window's build was raised \(raised.count) times for 3 keys")

        // The controller is built; once its focus resolved, the keys are decided in the order typed.
        let controller = try #require(services.windows.openWindow(id: id, workspaces: ["late-workspace"]))
        let target = LaunchPictureKeys.Target(window: id, pane: "late-pane", tab: "late-tab")
        try Self.focusTerminal(of: controller, workspace: "late-workspace", pane: "late-pane", tab: "late-tab")
        router.focusDidSettle(controller.focus.state, in: controller.window)
        #expect(!keys.isHoldingUndecided(window: id), "the keys still wait after the window's focus resolved")
        #expect(keys.isHolding(target), "the replayed keys did not reach the focused terminal's stand-in buffer")
        #expect(keys.dropped == 0)
    }

    // MARK: Keys, delivered to a real terminal view

    /// One workspace, one pane, one terminal tab (surface 1).
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "live-ws"), name: "live", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "live-ws"), index: 0)])
        return tree
    }

    /// Keys typed while the focused pane's terminal view is not in the window reach that view through the router's
    /// own delivery (its live-surface lookup and `keyDown`) once it is: each key exactly once, in order, and the
    /// router consumed each when typed, so AppKit's dispatch never gave it to anything else.
    @Test func eachKeyReachesTheLiveTerminalViewExactlyOnceInOrder() async throws {
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
        let controller = try #require(services.windows.openWindow(workspaces: ["live-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        let scripted = ScriptedTerminalIO()
        defer {
            scripted.finish()
            controller.teardown()
            controller.window?.close()
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent, "the window never showed its workspace")
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let pane = try #require(content.paneController(key: model.id))
        if pane.currentTabKey == nil { pane.showSelected() }
        let tab = try #require(pane.currentTabKey, "the pane shows no tab")
        let shell = try #require(controller.window)

        // The tab's terminal: a real Ghostty view on a scripted IO, not in the window yet (still a picture).
        let session = TerminalSession(io: scripted, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let tabModel = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let attachment = TerminalAttachment.Target(surface: tabModel.surface, terminalResourceID: nil, generation: nil)
        let io = DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: ResizeCoordinator(),
                                  visible: false, connection: { throw CancellationError() })
        services.cache.terminals[tab]?.session.view.removeFromSuperview()
        services.cache.terminals[tab] = TerminalEntry(validity: "test", session: session, io: io,
                                                      themeKey: TerminalThemeKey(machine: services.daemon.machineID, tab: tabModel),
                                                      store: store, surface: tabModel.surface, mainWork: services.mainWork)
        try Self.focusTerminal(of: controller, workspace: "live-ws", pane: pane.paneKey, tab: tab)
        let router = services.keyRouter, keys = router.launchPictureKeys
        let target = LaunchPictureKeys.Target(window: controller.state.id, pane: pane.paneKey, tab: tab)
        keys.begin(window: target.window, shell: shell) { _ in }

        for (letter, code) in [("e", UInt16(14)), ("c", 8), ("h", 4), ("o", 31)] {
            let event = try Self.key(letter, keyCode: code, window: shell.windowNumber)
            #expect(Self.dispatch(event, in: shell, router: router), "\(letter) went on to AppKit while its terminal was a picture")
        }
        #expect(keys.isHolding(target))
        #expect(scripted.writes.isEmpty, "a key reached the terminal before it was live")

        // The terminal goes live in its pane and takes the keyboard; the picture leaves.
        session.view.frame = pane.view.bounds
        pane.view.addSubview(session.view)
        session.view.layoutSubtreeIfNeeded()
        try #require(shell.makeFirstResponder(session.surfaceView), "the live terminal never took the keyboard")
        keys.end(window: target.window)
        #expect(!keys.isHolding(target), "the keys still wait for a live terminal")
        #expect(!keys.isActive && !router.modes.contains(.launchPicture))

        func written() -> String { String(decoding: scripted.writes.reduce(Data(), +), as: UTF8.self) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !written().contains("echo"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))  // a key typed twice would show by now
        #expect(written().components(separatedBy: "echo").count == 2, "the terminal got \(written().debugDescription), not echo once")
        #expect(!written().contains("eecchhoo"), "each key reached the terminal twice: \(written().debugDescription)")

        // With nothing waiting, the next key takes the usual path to the live terminal.
        let after = try Self.key("!", keyCode: 18, modifiers: .shift, window: shell.windowNumber)
        #expect(!Self.dispatch(after, in: shell, router: router), "a key for the live terminal waited")
    }

    /// A Kotoeri-like input method (Romaji): letters compose (ka is か), Return commits the
    /// preedit. It runs in the terminal view's input-method turn, so it sees each key when the
    /// view interprets it, as Kotoeri does.
    private final class FakeKotoeri {
        var romaji = ""
        let kana = ["ka": "か", "na": "な"]

        func interpret(_ view: TerminalSurfaceView, _ key: NSEvent) {
            let none = NSRange(location: NSNotFound, length: 0)
            if key.keyCode == 36 {
                let commit = kana[romaji] ?? romaji
                romaji = ""
                commit.isEmpty ? view.doCommand(by: #selector(NSResponder.insertNewline(_:))) : view.insertText(commit, replacementRange: none)
                return
            }
            romaji += key.characters ?? ""
            if let done = kana[romaji] {
                view.setMarkedText(done, selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
                romaji = done == "か" ? "ka" : "na"
                return
            }
            view.setMarkedText(romaji, selectedRange: NSRange(location: (romaji as NSString).length, length: 0), replacementRange: none)
        }
    }

    /// T4 (input-languages.md): keys typed with Kotoeri while the focused terminal is still a launch
    /// picture reach the live terminal's input method, in order, so the program gets the same
    /// committed text as when typed live (か), never the romaji the keys carry (ka).
    @Test func keysHeldForAPictureComposeThroughTheInputMethodOnceLive() async throws {
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
        let controller = try #require(services.windows.openWindow(workspaces: ["live-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        let scripted = ScriptedTerminalIO()
        defer {
            scripted.finish()
            controller.teardown()
            controller.window?.close()
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent, "the window never showed its workspace")
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let pane = try #require(content.paneController(key: model.id))
        if pane.currentTabKey == nil { pane.showSelected() }
        let tab = try #require(pane.currentTabKey, "the pane shows no tab")
        let shell = try #require(controller.window)
        let session = TerminalSession(io: scripted, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let kotoeri = FakeKotoeri()
        session.surfaceView.inputMethod = { view, key in kotoeri.interpret(view, key) }
        let tabModel = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let attachment = TerminalAttachment.Target(surface: tabModel.surface, terminalResourceID: nil, generation: nil)
        let io = DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: ResizeCoordinator(),
                                  visible: false, connection: { throw CancellationError() })
        services.cache.terminals[tab]?.session.view.removeFromSuperview()
        services.cache.terminals[tab] = TerminalEntry(validity: "test", session: session, io: io,
                                                      themeKey: TerminalThemeKey(machine: services.daemon.machineID, tab: tabModel),
                                                      store: store, surface: tabModel.surface, mainWork: services.mainWork)
        try Self.focusTerminal(of: controller, workspace: "live-ws", pane: pane.paneKey, tab: tab)
        let router = services.keyRouter, keys = router.launchPictureKeys
        let target = LaunchPictureKeys.Target(window: controller.state.id, pane: pane.paneKey, tab: tab)
        keys.begin(window: target.window, shell: shell) { _ in }

        for (letter, code) in [("k", UInt16(40)), ("a", 0), ("\r", 36)] {
            let event = try Self.key(letter, keyCode: code, window: shell.windowNumber)
            #expect(Self.dispatch(event, in: shell, router: router), "\(letter.debugDescription) went on to AppKit while its terminal was a picture")
        }
        #expect(scripted.writes.isEmpty, "a key reached the terminal before it was live")

        session.view.frame = pane.view.bounds
        pane.view.addSubview(session.view)
        session.view.layoutSubtreeIfNeeded()
        try #require(shell.makeFirstResponder(session.surfaceView), "the live terminal never took the keyboard")
        keys.end(window: target.window)

        func written() -> String { String(decoding: scripted.writes.reduce(Data(), +), as: UTF8.self) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !written().contains("か"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(written() == "か", "the program got \(written().debugDescription), not the committed か once")
        #expect(!session.surfaceView.hasMarkedText(), "the composition stayed open")
    }

    // MARK: Keys, the stand-in buffer

    private final class FakeTerminals {
        var live: Set<LaunchPictureKeys.Target> = []
        var received: [LaunchPictureKeys.Target: [String]] = [:]

        func deliver(_ target: LaunchPictureKeys.Target, _ events: [NSEvent]) -> Bool {
            guard live.contains(target) else { return false }
            received[target, default: []] += events.map { $0.characters ?? "" }
            return true
        }
    }

    private static let a = LaunchPictureKeys.Target(window: "w", pane: "pane-a", tab: "tab-a")
    private static let b = LaunchPictureKeys.Target(window: "w", pane: "pane-b", tab: "tab-b")

    /// Keys typed for a terminal reach it exactly once, in order, when it goes live; a focus move between them
    /// (a chord ran its action) sends the later keys to the new terminal, never the earlier ones.
    @Test func eachKeyReachesTheTerminalItWasTypedForExactlyOnce() throws {
        let terminals = FakeTerminals()
        let keys = LaunchPictureKeys { terminals.deliver($0, $1) }
        keys.begin(window: "w", shell: nil) { _ in }
        for letter in ["e", "c", "h", "o"] { keys.hold(try Self.key(letter, keyCode: 0), for: Self.a) }
        for letter in ["x", "y"] { keys.hold(try Self.key(letter, keyCode: 0), for: Self.b) }
        keys.retry()
        #expect(terminals.received.isEmpty, "a key reached a terminal that is not live")

        terminals.live.insert(Self.b)
        keys.retry()
        terminals.live.insert(Self.a)
        keys.end(window: "w")
        keys.retry()
        #expect(terminals.received[Self.a] == ["e", "c", "h", "o"])
        #expect(terminals.received[Self.b] == ["x", "y"])
        #expect(!keys.isActive && keys.dropped == 0)
    }

    /// Undecided keys go through the replay in order, ahead of the keys typed after them, exactly once.
    @Test func undecidedKeysReplayInOrderExactlyOnce() throws {
        var replayed: [String] = []
        var canDecide = false
        let keys = LaunchPictureKeys { _, _ in false }
        keys.replay = { _, events in
            guard canDecide else { return false }
            replayed += events.map { $0.characters ?? "" }
            return true
        }
        keys.begin(window: "w", shell: nil) { _ in }
        for letter in ["1", "2", "3"] { keys.holdUndecided(try Self.key(letter, keyCode: 0), window: "w") }
        keys.retry()
        #expect(replayed.isEmpty && keys.isHoldingUndecided(window: "w"))
        canDecide = true
        keys.retry()
        keys.retry()
        #expect(replayed == ["1", "2", "3"])
        #expect(!keys.isHoldingUndecided(window: "w"))
    }

    /// A key for a terminal that is live already goes at once, behind the keys typed for it before.
    @Test func aKeyForALiveTerminalGoesAtOnceBehindTheEarlierOnes() throws {
        let terminals = FakeTerminals()
        let keys = LaunchPictureKeys { terminals.deliver($0, $1) }
        keys.begin(window: "w", shell: nil) { _ in }
        keys.hold(try Self.key("1", keyCode: 18), for: Self.a)
        terminals.live.insert(Self.a)
        keys.hold(try Self.key("2", keyCode: 19), for: Self.a)
        #expect(terminals.received[Self.a] == ["1", "2"])
        #expect(!keys.isHolding(Self.a))
    }

    /// The test phase's burst, at the model: in 10 launches, a burst typed 10 ms after the first frame loses no key,
    /// whenever in the picture phase the terminal goes live.
    @Test func aBurstTenMillisecondsAfterTheFirstFrameLosesNoKeyInTenLaunches() throws {
        for launch in 0 ..< 10 {
            let start = ContinuousClock.now
            var elapsed = Duration.milliseconds(10)
            let terminals = FakeTerminals()
            let keys = LaunchPictureKeys(now: { start + elapsed }) { terminals.deliver($0, $1) }
            keys.begin(window: "w", shell: nil) { _ in }
            let burst = (0 ..< 20).map { "k\(launch)-\($0)" }
            for (index, text) in burst.enumerated() {
                keys.hold(try Self.key(text, keyCode: 0), for: Self.a)
                elapsed += .milliseconds(8)
                // The terminal's first frame lands somewhere in the burst (later each launch).
                if index == launch * 2 { terminals.live.insert(Self.a) }
            }
            keys.end(window: "w")
            #expect(terminals.received[Self.a] == burst, "launch \(launch) lost or reordered keys")
            #expect(keys.dropped == 0)
        }
    }

    /// A terminal that never goes live does not keep its keys (or the router's slow path) forever.
    @Test func keysForATerminalThatNeverGoesLiveAreDroppedAfterTheLimit() throws {
        let start = ContinuousClock.now
        var elapsed = Duration.zero
        var active: [Bool] = []
        let keys = LaunchPictureKeys(limit: .seconds(5), now: { start + elapsed }) { _, _ in false }
        keys.onActiveChange = { active.append($0) }
        keys.begin(window: "w", shell: nil) { _ in }
        keys.hold(try Self.key("z", keyCode: 6), for: Self.a)
        keys.end(window: "w")
        #expect(keys.isActive, "the key was dropped before its limit")
        elapsed = .seconds(6)
        keys.retry()
        #expect(!keys.isActive && keys.dropped == 1)
        #expect(active == [true, false])
    }
}
