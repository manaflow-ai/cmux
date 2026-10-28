import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextLaunch
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import Testing

/// Keys while a window shows its launch picture (p08-startup-061). A key changes only the model in its turn: an
/// action runs (a Command chord, a Control chord, a chord's leader and the key after it), a key the window cannot
/// decide yet waits whole and goes through the router again once it can, and typing for a terminal that is still a
/// picture goes at once to that terminal's input by its id (the daemon queues it), raises the pane's slice to the next
/// frame, and reaches the terminal exactly once, in order, before any key typed after its view went live. No key is
/// dropped silently: one that cannot reach its terminal is refused visibly and kept. Clicks: `LaunchPictureClickTests`.
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

    /// Typing while the focused terminal is a picture goes to it by its id at once: the router takes each key, sends
    /// it in order, raises the pane's slice once (not per key, and only that pane), and turns its mode on only while
    /// the picture shows.
    @Test func typingForATerminalStillAPictureGoesToItByIdAndRaisesOnlyItsPane() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let terminals = FakeTerminals()
        harness.keys.forward = { terminals.forward($0, $1, $2) }
        var raised: [String?] = []
        #expect(!harness.router.modes.contains(.launchPicture))
        harness.keys.begin(window: harness.target.window, shell: harness.shell) { raised.append($0) }
        #expect(harness.router.modes.contains(.launchPicture), "the picture phase did not turn the router's mode on")

        for (letter, code) in [("l", UInt16(37)), ("s", 1), ("\r", 36)] {
            let event = try Self.key(letter, keyCode: code, window: harness.shell.windowNumber)
            #expect(Self.dispatch(event, in: harness.shell, router: harness.router),
                    "the key for a terminal still a picture went on to a view that cannot take it")
        }
        #expect(terminals.forwarded[harness.target] == ["l", "s", "\r"], "sent \(terminals.forwarded) by id")
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
        let terminals = FakeTerminals()
        harness.keys.forward = { terminals.forward($0, $1, $2) }
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
        #expect(terminals.forwarded.isEmpty, "a key of the chord went to the terminal as input")

        let unbound = try Self.key("\u{03}", keyCode: 8, modifiers: .control, ignoringModifiers: "c", window: harness.shell.windowNumber)
        #expect(Self.dispatch(unbound, in: harness.shell, router: harness.router))
        #expect(terminals.forwarded[harness.target] == ["\u{03}"], "an unbound Control key is the terminal's: it goes to it")
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

    /// Keys typed in the picture's window before it has a controller, with no saved focus to send them to, wait
    /// whole, in order, and raise the window's build; once the controller exists and its focus resolved, they go
    /// through the router again and on to the focused terminal by its id. A key typed meanwhile goes behind them.
    @Test func keysTypedBeforeTheWindowHasAControllerWaitForIt() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let router = services.keyRouter, keys = router.launchPictureKeys
        let terminals = FakeTerminals()
        keys.forward = { terminals.forward($0, $1, $2) }
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
        #expect(terminals.forwarded[target] == ["e", "c", "h"], "the replayed keys did not reach the focused terminal")
        #expect(keys.refused == 0)
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

    /// Keys typed while the focused pane's terminal view is not in the window go to the terminal by id at once; the
    /// ones typed while that send is on its way reach the view through the router's own delivery (its live-surface
    /// lookup and `keyDown`) once the view is live and the daemon took the first: each key exactly once, in order, and
    /// the router consumed each when typed, so AppKit's dispatch never gave it to anything else.
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
                                  visible: false, endpoint: { throw CancellationError() })
        services.cache.terminals[tab]?.session.view.removeFromSuperview()
        services.cache.terminals[tab] = TerminalEntry(validity: "test", session: session, io: io,
                                                      themeKey: TerminalThemeKey(machine: services.daemon.machineID, tab: tabModel),
                                                      store: store, surface: tabModel.surface, mainWork: services.mainWork)
        try Self.focusTerminal(of: controller, workspace: "live-ws", pane: pane.paneKey, tab: tab)
        let router = services.keyRouter, keys = router.launchPictureKeys
        let terminals = FakeTerminals()
        terminals.answersAtOnce = false
        keys.forward = { terminals.forward($0, $1, $2) }
        let target = LaunchPictureKeys.Target(window: controller.state.id, pane: pane.paneKey, tab: tab)
        keys.begin(window: target.window, shell: shell) { _ in }

        for (letter, code) in [("e", UInt16(14)), ("c", 8), ("h", 4), ("o", 31)] {
            let event = try Self.key(letter, keyCode: code, window: shell.windowNumber)
            #expect(Self.dispatch(event, in: shell, router: router), "\(letter) went on to AppKit while its terminal was a picture")
        }
        #expect(terminals.forwarded[target] == ["e"], "the first key did not go to the terminal by id at once")
        #expect(keys.isHolding(target))
        #expect(scripted.writes.isEmpty, "a key reached the terminal view before it was live")

        // The terminal goes live in its pane and takes the keyboard; the picture leaves.
        session.view.frame = pane.view.bounds
        pane.view.addSubview(session.view)
        session.view.layoutSubtreeIfNeeded()
        try #require(shell.makeFirstResponder(session.surfaceView), "the live terminal never took the keyboard")
        keys.end(window: target.window)
        #expect(scripted.writes.isEmpty, "a key overtook the one still on its way by id")
        terminals.answer()
        #expect(!keys.isHolding(target), "the keys still wait for a live terminal")
        #expect(!keys.isActive && !router.modes.contains(.launchPicture))

        func written() -> String { String(decoding: scripted.writes.reduce(Data(), +), as: UTF8.self) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !written().contains("cho"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))  // a key typed twice would show by now
        #expect(written().components(separatedBy: "cho").count == 2, "the view got \(written().debugDescription), not cho once")
        #expect(!written().contains("e"), "the key the daemon took also reached the view: \(written().debugDescription)")
        #expect(!written().contains("cchhoo"), "each key reached the terminal twice: \(written().debugDescription)")
        #expect(terminals.arrived[target] == ["e"])

        // With nothing waiting, the next key takes the usual path to the live terminal.
        let after = try Self.key("!", keyCode: 18, modifiers: .shift, window: shell.windowNumber)
        #expect(!Self.dispatch(after, in: shell, router: router), "a key for the live terminal waited")
    }

    // MARK: Keys, the stand-in buffer

    /// A refusal the buffer reported: the window, the text it kept for the person, and why.
    private struct Refusal: Equatable {
        let window: String
        let text: String
        let reason: String?
    }

    /// Terminals as the buffer reaches them: a live view (`deliver`) and the daemon's input queue by the terminal's
    /// id (`forward`). `arrived` is what each terminal got by either path, in the order it got it: a key sent by id
    /// arrives when the daemon took it.
    private final class FakeTerminals {
        var live: Set<LaunchPictureKeys.Target> = []
        var received: [LaunchPictureKeys.Target: [String]] = [:]
        var forwarded: [LaunchPictureKeys.Target: [String]] = [:]
        var arrived: [LaunchPictureKeys.Target: [String]] = [:]
        /// False: a send waits for ``answer()`` (the daemon's reply has not come).
        var answersAtOnce = true
        /// What the daemon answers a send with: nil takes it.
        var refusal: String?
        private var unanswered: [(target: LaunchPictureKeys.Target, texts: [String], answered: @MainActor (String?) -> Void)] = []

        func deliver(_ target: LaunchPictureKeys.Target, _ events: [NSEvent]) -> Bool {
            guard live.contains(target) else { return false }
            let texts = events.map { $0.characters ?? "" }
            received[target, default: []] += texts
            arrived[target, default: []] += texts
            return true
        }

        /// One send to the daemon: `events` in order, answered once for all of them.
        func forward(_ target: LaunchPictureKeys.Target, _ events: [NSEvent], _ answered: @escaping @MainActor (String?) -> Void) {
            let texts = events.map { $0.characters ?? "" }
            forwarded[target, default: []] += texts
            if answersAtOnce { take(target, texts, answered) } else { unanswered.append((target, texts, answered)) }
        }

        /// The daemon answers every send waiting for it, in order.
        func answer() {
            let waiting = unanswered
            unanswered = []
            for send in waiting { take(send.target, send.texts, send.answered) }
        }

        private func take(_ target: LaunchPictureKeys.Target, _ texts: [String], _ answered: @MainActor (String?) -> Void) {
            if refusal == nil { arrived[target, default: []] += texts }
            answered(refusal)
        }
    }

    private static func buffer(_ terminals: FakeTerminals) -> LaunchPictureKeys {
        let keys = LaunchPictureKeys { terminals.deliver($0, $1) }
        keys.forward = { terminals.forward($0, $1, $2) }
        return keys
    }

    private static let a = LaunchPictureKeys.Target(window: "w", pane: "pane-a", tab: "tab-a")
    private static let b = LaunchPictureKeys.Target(window: "w", pane: "pane-b", tab: "tab-b")

    /// A key typed for a terminal that is still a picture goes at once to that terminal's input by its id, in the
    /// order typed, before its view is live: nothing waits for the view. One send is on its way at a time, so the
    /// daemon writes them in order.
    @Test func aKeyForATerminalStillAPictureGoesToItsTerminalByIdAtOnce() throws {
        let terminals = FakeTerminals()
        terminals.answersAtOnce = false
        let keys = Self.buffer(terminals)
        keys.begin(window: "w", shell: nil) { _ in }
        keys.hold(try Self.key("e", keyCode: 14), for: Self.a)
        #expect(terminals.forwarded[Self.a] == ["e"], "the key waited for the terminal's view instead of going by its id")
        keys.hold(try Self.key("c", keyCode: 8), for: Self.a)
        keys.hold(try Self.key("x", keyCode: 7), for: Self.b)
        #expect(terminals.forwarded[Self.a] == ["e"], "a key overtook the one before it on its way to the daemon")
        #expect(terminals.forwarded[Self.b] == ["x"], "another terminal's key waited behind this one's")
        terminals.answer()
        terminals.answer()
        #expect(terminals.forwarded[Self.a] == ["e", "c"])
        #expect(terminals.arrived[Self.a] == ["e", "c"] && terminals.arrived[Self.b] == ["x"])
        #expect(terminals.received.isEmpty, "a key reached a view that is not live")
        #expect(!keys.isHolding(Self.a) && !keys.isHolding(Self.b), "keys the daemon took still wait")
    }

    /// Keys typed after the view went live come after the ones sent by id, each exactly once: while a key sent by id
    /// is on its way, later keys wait behind it; once the daemon took it, the live view takes the rest, in order.
    @Test func keysTypedAfterTheViewWentLiveComeAfterTheEarlierOnes() throws {
        let terminals = FakeTerminals()
        terminals.answersAtOnce = false
        let keys = Self.buffer(terminals)
        keys.begin(window: "w", shell: nil) { _ in }
        keys.hold(try Self.key("1", keyCode: 18), for: Self.a)
        keys.hold(try Self.key("2", keyCode: 19), for: Self.a)
        terminals.live.insert(Self.a)
        keys.hold(try Self.key("3", keyCode: 20), for: Self.a)
        #expect(terminals.received.isEmpty, "a key went to the live view ahead of keys still on their way by id")
        while keys.isHolding(Self.a) { terminals.answer() }
        keys.hold(try Self.key("4", keyCode: 21), for: Self.a)
        keys.end(window: "w")
        #expect(terminals.arrived[Self.a] == ["1", "2", "3", "4"], "the terminal got \(terminals.arrived[Self.a] ?? [])")
        #expect(terminals.forwarded[Self.a] == ["1"] && terminals.received[Self.a] == ["2", "3", "4"])
        #expect(!keys.isActive && keys.refused == 0)
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

    /// The test phase's burst, at the model: in 10 launches, a burst typed 10 ms after the first frame loses no key
    /// and reorders none, whenever in the picture phase the terminal goes live and the daemon answers.
    @Test func aBurstTenMillisecondsAfterTheFirstFrameLosesNoKeyInTenLaunches() throws {
        for launch in 0 ..< 10 {
            let terminals = FakeTerminals()
            terminals.answersAtOnce = false
            let keys = Self.buffer(terminals)
            keys.begin(window: "w", shell: nil) { _ in }
            let burst = (0 ..< 20).map { "k\(launch)-\($0)" }
            for (index, text) in burst.enumerated() {
                keys.hold(try Self.key(text, keyCode: 0), for: Self.a)
                // The daemon answers every third key; the terminal's first frame lands somewhere in the burst.
                if index % 3 == launch % 3 { terminals.answer() }
                if index == launch * 2 { terminals.live.insert(Self.a) }
            }
            while keys.isHolding(Self.a) { terminals.answer() }
            keys.end(window: "w")
            #expect(terminals.arrived[Self.a] == burst, "launch \(launch) lost or reordered keys")
            #expect(keys.refused == 0 && !keys.isActive)
        }
    }

    /// A terminal that never goes live: nothing is dropped silently. Keys the daemon has not answered keep waiting for
    /// it (no time limit drops them); a key it refuses, and every key behind it, is refused visibly, with the text
    /// kept for the person.
    @Test func aTerminalThatNeverGoesLiveDropsNothingSilently() throws {
        let terminals = FakeTerminals()
        terminals.answersAtOnce = false
        var refusals: [Refusal] = []
        var active: [Bool] = []
        let keys = Self.buffer(terminals)
        keys.refuse = { refusals.append(Refusal(window: $0, text: $1, reason: $2)) }
        keys.onActiveChange = { active.append($0) }
        keys.begin(window: "w", shell: nil) { _ in }
        for (letter, code) in [("l", UInt16(37)), ("s", 1), ("\r", 36)] { keys.hold(try Self.key(letter, keyCode: code), for: Self.a) }
        keys.end(window: "w")
        keys.retry()
        #expect(keys.isActive && keys.isHolding(Self.a), "keys still on their way to the daemon were dropped")
        #expect(refusals.isEmpty && keys.refused == 0)

        terminals.refusal = "no such terminal"
        terminals.answer()
        #expect(refusals == [Refusal(window: "w", text: "ls\r", reason: "no such terminal")], "refused \(refusals)")
        #expect(keys.refused == 3)
        #expect(!keys.isActive && active == [true, false])
    }

    /// With nothing to send a terminal's keys to, they are refused visibly and kept, never dropped.
    @Test func keysWithNoWayToTheirTerminalAreRefusedAndKept() throws {
        var refusals: [Refusal] = []
        let keys = LaunchPictureKeys { _, _ in false }
        keys.refuse = { refusals.append(Refusal(window: $0, text: $1, reason: $2)) }
        keys.begin(window: "w", shell: nil) { _ in }
        keys.hold(try Self.key("z", keyCode: 6), for: Self.a)
        #expect(refusals == [Refusal(window: "w", text: "z", reason: nil)])
        #expect(keys.refused == 1 && !keys.isHolding(Self.a))
    }

    /// Keys the window could still not decide when its picture left (it closed before its controller was built) are
    /// refused visibly and kept, never dropped.
    @Test func undecidedKeysTheWindowNeverDecidesAreRefusedAndKept() throws {
        var refusals: [Refusal] = []
        let keys = LaunchPictureKeys { _, _ in false }
        keys.replay = { _, _ in false }
        keys.refuse = { refusals.append(Refusal(window: $0, text: $1, reason: $2)) }
        keys.begin(window: "w", shell: nil) { _ in }
        for letter in ["c", "d"] { keys.holdUndecided(try Self.key(letter, keyCode: 0), window: "w") }
        keys.retry()
        #expect(refusals.isEmpty && keys.isHoldingUndecided(window: "w"), "undecided keys were given up while the picture showed")
        keys.end(window: "w")
        #expect(refusals == [Refusal(window: "w", text: "cd", reason: nil)])
        #expect(!keys.isActive && keys.refused == 2)
    }

    /// A key sent by id is what the terminal takes for it: text a key commits is that text; a key Ghostty encodes
    /// from the key itself goes by its `send-key` name, for the daemon to encode with the program's modes; a
    /// Command chord is never typing.
    @Test func aKeySentByIdIsWhatTheTerminalTakesForIt() throws {
        #expect(TypedTerminalInput(try Self.key("a", keyCode: 0)) == .text("a"))
        #expect(TypedTerminalInput(try Self.key("A", keyCode: 0, modifiers: .shift, ignoringModifiers: "a")) == .text("A"))
        #expect(TypedTerminalInput(try Self.key("!", keyCode: 18, modifiers: .shift, ignoringModifiers: "1")) == .text("!"))
        #expect(TypedTerminalInput(try Self.key("é", keyCode: 14, modifiers: .option, ignoringModifiers: "e")) == .text("é"))
        #expect(TypedTerminalInput(try Self.key("\r", keyCode: 36)) == .key("enter"))
        #expect(TypedTerminalInput(try Self.key("\u{7f}", keyCode: 51)) == .key("backspace"))
        #expect(TypedTerminalInput(try Self.key("\t", keyCode: 48, modifiers: .shift)) == .key("shift+tab"))
        #expect(TypedTerminalInput(try Self.key(Shortcut.upArrowKey, keyCode: 126)) == .key("up"))
        #expect(TypedTerminalInput(try Self.key("\u{03}", keyCode: 8, modifiers: .control, ignoringModifiers: "c")) == .key("ctrl+c"))
        #expect(TypedTerminalInput(try Self.key("k", keyCode: 40, modifiers: .command)) == nil)
    }

    // MARK: Keys typed before the window decides, to its restored focus

    /// Keys typed in a window showing its picture before it has a controller go by id to the terminal its saved
    /// session restores focus to, at once; a chord there waits whole for the window to decide it (it may be a cmux
    /// shortcut), and a key typed after it queues behind it (none overtakes another).
    @Test func keysTypedBeforeTheWindowDecidesGoToItsRestoredFocusedTerminal() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let pane = try #require(store.workspaces.first?.screens.first?.panes.first)
        let tab = try #require(pane.tabs.first)
        let id = "restored-window"
        let state = WindowState(id: id, workspaceID: "live-ws")
        state.savedFocusedPane = pane.id
        state.selection.select(tab.id, in: pane.id)
        services.windows.states[id] = state

        let router = services.keyRouter, keys = router.launchPictureKeys
        let terminals = FakeTerminals()
        keys.forward = { terminals.forward($0, $1, $2) }
        let picture = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        picture.isReleasedWhenClosed = false
        defer { picture.close() }
        keys.begin(window: id, shell: picture) { _ in }

        let target = LaunchPictureKeys.Target(window: id, pane: pane.id, tab: tab.id)
        for (letter, code) in [("l", UInt16(37)), ("s", 1)] {
            #expect(Self.dispatch(try Self.key(letter, keyCode: code, window: picture.windowNumber), in: picture, router: router))
        }
        #expect(terminals.forwarded[target] == ["l", "s"], "sent \(terminals.forwarded): not to the restored focused terminal")
        #expect(!keys.isHoldingUndecided(window: id), "keys with a known target waited for the window to decide them")

        let chord = try Self.key("\u{02}", keyCode: 11, modifiers: .control, ignoringModifiers: "b", window: picture.windowNumber)
        #expect(Self.dispatch(chord, in: picture, router: router))
        #expect(keys.isHoldingUndecided(window: id), "a chord typed before the window decides was not kept for it")
        #expect(Self.dispatch(try Self.key("x", keyCode: 7, window: picture.windowNumber), in: picture, router: router))
        #expect(terminals.forwarded[target] == ["l", "s"], "a key overtook the chord typed before it")
    }
}
