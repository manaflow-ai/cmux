import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
import Foundation
import Testing

/// A person presses Cmd-T (or Cmd-N, or clicks the + of a pane) and types a line with Return before the new
/// page's field is ready. The window's key hold (`NewTabInputCoordinator`) has the line. When the hold ends
/// with no field ready, it gives its keys on to what has the keyboard then. Until the new page takes the
/// keyboard, that is the view that had it before the opening: a terminal. So the line ran in a terminal
/// the person did not type it in. The ends where this was so:
///
/// - the Cmd-W KEY that closes the page (the hold's chord rule gave the keys on before the close ran; the
///   Close Tab ACTION discards them through `CreationInputCoordinator.drop(tab:in:)`);
/// - the hold's limit, with the page in a pane that is not the focused one (a slow start; no close at all);
/// - Cmd-N whose creation failed, and Cmd-N at its limit;
/// - an opening that failed;
/// - a second opening that is not a key (a click on +, a menu pick, a script): it replaced the hold.
///
/// The rule for every end: a key typed after the opening never goes to what had the keyboard at the
/// opening. A view that took the keyboard after the opening still gets the keys, in order, and the keys of
/// a replaced hold wait for the newer page.
///
/// The view that has the keyboard here is a probe that stands for that terminal. It must get no key.
@MainActor @Suite(.serialized)
struct NewTabHoldCloseKeyTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// Stands for the terminal that had the keyboard before Cmd-T: it records each key it gets.
    private final class KeyProbe: NSView {
        var typed = ""
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { typed += event.characters ?? "" }
    }

    /// One workspace with one pane, or with two side by side; each pane has one tab. `secondWorkspace`: one more
    /// workspace with one pane, for a second window.
    private static func tree(panes: Int, secondWorkspace: Bool = false) -> DaemonTree {
        let all = (1...panes).map { PaneSnapshot(id: PaneID(rawValue: UInt64($0)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "~")]) }
        let layout: LayoutNode = panes == 1 ? .leaf(all[0].id)
            : .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(all[0].id), b: .leaf(all[1].id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: all)
        var workspaces = [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "hold-close-ws"), name: "hold", screens: [screen])]
        var personal = [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "hold-close-ws"), index: 0)]
        if secondWorkspace {
            let pane = PaneSnapshot(id: PaneID(rawValue: 11), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 11), title: "~")])
            let second = ScreenSnapshot(id: ScreenID(rawValue: 2), layout: .leaf(pane.id), panes: [pane])
            workspaces.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "hold-close-ws-b"), name: "other", screens: [second]))
            personal.append(PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "hold-close-ws-b"), index: 1))
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: workspaces)
        tree.personal = PersonalState(workspaces: personal)
        return tree
    }

    private static func keyDown(_ character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    /// A run of the CLI that may not change the view, as `ActionRegistry` binds it for the handler.
    private static let scriptRun = ActionRunScope(origin: .cli, allowsViewChange: false)

    /// The keys that a test left in the router's menu-pick hold (`KeyRouter.menuPickKeys`). That hold sends each one on
    /// with `NSApp.sendEvent` on a later turn of the main actor, after the menu's end: after the body of the test, and
    /// with no wait after its teardown too, where each key monitor of the process got the key inside a test of another
    /// suite. `withAHeldLine` waits here until the app sent each key on, and the key goes no further: no window gets it.
    @MainActor private final class MenuPickKeysSentLater {
        private var owed: [NSEvent] = []
        private var monitor: Any?

        /// The router's menu-pick hold has `event`.
        func owes(_ event: NSEvent) {
            owed.append(event)
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] sent in
                guard let self, let index = self.owed.firstIndex(where: { $0 === sent || ($0.timestamp == sent.timestamp && $0.keyCode == sent.keyCode && $0.windowNumber == sent.windowNumber) })
                else { return sent }
                self.owed.remove(at: index)
                return nil
            }
        }

        /// Waits until the app sent each owed key on (2 s at most), then stops the watch.
        func settle() async {
            for _ in 0..<200 where !owed.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            #expect(owed.isEmpty, "\(owed.count) key(s) of the router's menu-pick hold were not sent on before the teardown: they run again inside a later test")
        }
    }

    /// What `withAHeldLine` made.
    @MainActor private struct Held {
        let services: AppServices
        let window: NSWindow
        /// The pane that shows the New Tab page.
        let pane: PaneController
        /// The tab key of the New Tab page.
        let tab: String
        /// The view that had the keyboard before the opening, and still has it.
        let probe: KeyProbe
        /// The hold's token.
        let token: String
        /// With `newWindowHold`: a second window of the app, its pane, and the probe that has the keyboard there.
        var other: (window: NSWindow, pane: PaneController, probe: KeyProbe)?
        var input: NewTabInputCoordinator { services.keyRouter.newTabInputCoordinator }
        /// The keys the test left in the router's menu-pick hold: `withAHeldLine` waits for them before its teardown.
        let sentLater = MenuPickKeysSentLater()

        /// A view that takes the keyboard after the opening (the new page's or the new terminal's). It is in the
        /// page's pane, which is the focused pane in each test that uses it: the window gives the keyboard back
        /// to the focused pane's terminal when a view outside every pane takes it.
        func laterKeyboardView() throws -> KeyProbe {
            let later = KeyProbe(frame: CGRect(x: 20, y: 0, width: 10, height: 10))
            pane.view.addSubview(later)
            try #require(window.makeFirstResponder(later) && window.firstResponder === later, "the second probe did not get the keyboard")
            return later
        }

        /// The hold's limit passes, and its deadline runs.
        func passTheLimit() {
            input.now = { ContinuousClock.now + .seconds(601) }
            input.flush(in: window)
        }
    }

    /// One window whose pane shows a New Tab page whose field is not ready, the hold of its opening
    /// (`incoming`: of Cmd-N's new workspace) with the line `ls` and Return in it, and the probe with the
    /// keyboard. With `besideTheFocusedPane` the page is in the second of two panes and the focus model names
    /// the first, as after a click on the + of a pane that is not the focused one. `body` ends the hold.
    /// `newWindowHold`: the hold is Cmd-Shift-N's (it takes the keys of every window), and the app has a second
    /// window whose pane has a probe with the keyboard.
    private static func withAHeldLine(incoming: Bool = false, besideTheFocusedPane: Bool = false, byScript: Bool = false, thenAScriptOpens: Bool = false, newWindowHold: Bool = false, _ body: (Held) throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let count = besideTheFocusedPane ? 2 : 1
        store.apply(snapshot: tree(panes: count, secondWorkspace: newWindowHold))
        let controller = try #require(services.windows.openWindow(workspaces: ["hold-close-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "new-tab-hold-close-\(UUID().uuidString)")
        var pageKey: String?
        var otherController: WindowController?
        defer {
            otherController?.teardown()
            otherController?.window?.close()
            if let pageKey {
                services.agentTabs.views[pageKey] = nil
                services.agentTabs.newTabPages[pageKey] = nil
            }
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<200 where controller.workspaceContent?.panes.count != count { try await Task.sleep(for: .milliseconds(10)) }
        let content = try #require(controller.workspaceContent)
        try #require(content.panes.count == count, "the window never showed the workspace's \(count) pane(s)")
        content.contentView.layoutSubtreeIfNeeded()
        let window = try #require(controller.window)
        let models = try #require(store.workspaces.first?.screens.first?.panes)
        try #require(models.count == count)
        let focused = try #require(content.paneController(key: models[0].id))
        let pane = try #require(content.paneController(key: models[count - 1].id))
        for _ in 0..<100 where pane.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
        if pane.currentTabKey == nil { pane.showSelected() }
        let tab = try #require(pane.currentTabKey, "the pane shows no tab")
        pageKey = tab

        // The pane's tab is a New Tab page whose field has not reported ready.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html><body><input></body></html>".utf8).write(to: file)
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        model.becomeNewTab(AgentPaneNewTab(kind: .agent))
        let page = try #require(AgentPaneView(model: model, source: .bundled(file)))
        page.frame = pane.view.bounds
        pane.view.addSubview(page)
        services.agentTabs.views[tab] = page
        services.agentTabs.newTabPages[tab] = (AgentPaneNewTab(kind: .agent),
                                               NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        try #require(page.window === window && !page.isHiddenOrHasHiddenAncestor, "the page is not shown in the window")

        // The second window: one pane, which has focus there, and a probe in it with that window's keyboard.
        var other: (window: NSWindow, pane: PaneController, probe: KeyProbe)?
        if newWindowHold {
            let second = try #require(services.windows.openWindow(workspaces: ["hold-close-ws-b"], frame: CGRect(x: 260, y: 240, width: 900, height: 600)), "the second window did not open")
            otherController = second
            for _ in 0..<200 where second.workspaceContent?.panes.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
            let secondContent = try #require(second.workspaceContent, "the second window shows no workspace")
            try #require(secondContent.panes.count == 1, "the second window never showed its pane")
            secondContent.contentView.layoutSubtreeIfNeeded()
            let secondWindow = try #require(second.window)
            try #require(secondWindow !== window, "the second workspace opened in the first window")
            // The hold table's key is the window number. A host with no window session gives a window no number: the 2
            // windows then have ONE key, and a test of which window has the hold proves nothing.
            try #require(secondWindow.windowNumber != window.windowNumber, "the 2 windows have the same window number (\(window.windowNumber)): this host gives a window no number, and this fixture proves nothing")
            let firstPanes = store.workspaces.compactMap { $0.screens.first?.panes.first }
            let secondPane = try #require(firstPanes.compactMap { secondContent.paneController(key: $0.id) }.first, "the second window has no pane controller")
            try #require(secondPane !== focused && secondPane !== pane && secondPane.view.window === secondWindow, "the second window's pane is not its own")
            // The pane shows its tab, as the first window's pane does. While the focused terminal of a window is not shown,
            // the creation hold takes each key of that window for it (`CreationInputCoordinator.capture`, awaited content):
            // a key that runs again there reaches no view, and a test of what the second window's keyboard gets proves nothing.
            for _ in 0..<100 where secondPane.currentTabKey == nil { try await Task.sleep(for: .milliseconds(10)) }
            if secondPane.currentTabKey == nil { secondPane.showSelected() }
            try #require(secondPane.currentTabKey != nil, "the second window's pane shows no tab")
            second.focus.send(.focusPane(secondPane.paneKey, source: .programmatic))
            for _ in 0..<100 where CreationInputCoordinator.awaitedContent(second) != nil { try await Task.sleep(for: .milliseconds(10)) }
            try #require(CreationInputCoordinator.awaitedContent(second) == nil, "the second window's focus still waits for content that is not shown (\(String(describing: CreationInputCoordinator.awaitedContent(second))), pane shows \(secondPane.currentTabKey ?? "-")): the creation hold takes that window's keys, so this fixture proves nothing")
            let secondProbe = KeyProbe(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            secondPane.view.addSubview(secondProbe)
            try #require(secondWindow.makeFirstResponder(secondProbe) && secondWindow.firstResponder === secondProbe, "the second window's probe did not get the keyboard (first responder \(String(describing: secondWindow.firstResponder)))")
            other = (window: secondWindow, pane: secondPane, probe: secondProbe)
        }

        // The focus model names the first pane, and the view that had the keyboard before the opening still has it.
        controller.focus.send(.focusPane(focused.paneKey, source: .programmatic))
        try #require(controller.focus.state.pane == focused.paneKey, "the first pane does not have focus")
        // The probe is in the focused pane, as that pane's terminal is: the focus model takes its keyboard for the
        // pane's content and leaves it there (a view outside every pane loses the keyboard to the pane's terminal).
        let probe = KeyProbe(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        focused.view.addSubview(probe)
        try #require(window.makeFirstResponder(probe) && window.firstResponder === probe, "the probe did not get the keyboard (first responder \(String(describing: window.firstResponder)))")

        // The opening's hold, as NewTabPage.open (or Cmd-N) begins it, and the line typed before the field is ready.
        let router = services.keyRouter
        let input = router.newTabInputCoordinator
        input.holdLimit = .seconds(600)
        input.incomingHoldLimit = .seconds(600)
        input.scheduleDeadline = { _, _ in Task {} }
        // `byScript`: the opening is a run of the CLI that may not change the view, as `ActionRegistry` binds it.
        var token = try #require(ActionRunScope.$current.withValue(byScript ? scriptRun : nil) { newWindowHold ? input.beginIncoming(in: window, followsNewWindow: true) : incoming ? input.beginIncoming(in: window) : input.begin(for: pane) })
        if !incoming, !newWindowHold { input.didShow(in: window) }
        // `thenAScriptOpens`: a script's opening in the same window replaces the hold before the first key.
        if thenAScriptOpens { token = try #require(ActionRunScope.$current.withValue(scriptRun) { input.begin(for: pane) }, "the script's opening began no hold") }
        let line = [try keyDown("l", keyCode: 37, in: window), try keyDown("s", keyCode: 1, in: window), try keyDown("\r", keyCode: 36, in: window)]
        for event in line { try #require(router.interceptKeyDown(event, in: window), "the hold did not take a key of the line: \(input.log)") }
        try #require(input.isHolding(in: window) && probe.typed.isEmpty, "the line is not held: probe \"\(probe.typed)\", \(input.log)")
        try #require(window.firstResponder === probe, "the keyboard left the probe before the hold ended (first responder \(String(describing: window.firstResponder)))")

        let held = Held(services: services, window: window, pane: pane, tab: tab, probe: probe, token: token, other: other)
        let end = Result { try body(held) }
        await held.sentLater.settle() // before the teardown (the `defer` above)
        try end.get()
    }

    /// What every test here needs from the end of a hold: it is over, and the old view got no key.
    private static func expectNoKeyReachedTheOldView(_ held: Held, _ end: String) {
        #expect(!held.input.isHolding(in: held.window), "the hold did not end (\(end)): \(held.input.log)")
        #expect(held.probe.typed.isEmpty, "\(end): the line typed for the new page went to the view that had the keyboard before the opening: \"\(held.probe.typed)\" (hold log \(held.input.log))")
    }

    @Test func aLineHeldForANewTabPageGoesToNoTerminalWhenTheCmdWKeyClosesThePage() async throws {
        try await Self.withAHeldLine { held in
            let close = try Self.keyDown("w", keyCode: 13, flags: .command, in: held.window)
            let resolved = held.services.registry.resolveShortcut(for: close)?.id
            try #require(resolved == "closeTab", "Cmd-W does not resolve to Close Tab here (\(String(describing: resolved))): this run proves nothing")
            // The step of `KeyRouter.interceptKeyDown` that runs before the key's action. The action itself
            // does not run here: the store of this test has no daemon to close the tab.
            #expect(!held.input.capture(close, in: held.window), "the hold took the Cmd-W key itself")
            Self.expectNoKeyReachedTheOldView(held, "the Cmd-W key")
        }
    }

    @Test func aLineHeldForANewTabPageGoesToNoTerminalWhenTheCloseTabActionClosesThePage() async throws {
        try await Self.withAHeldLine { held in
            // What `TabLifecycle.close` and `PaneCommands` run for a page that closes before the daemon made it.
            held.services.keyRouter.creationInputCoordinator.drop(tab: held.tab, in: held.window)
            Self.expectNoKeyReachedTheOldView(held, "the Close Tab action")
        }
    }

    /// A slow start of a page in a pane that is not the focused one (a click on its +): the page's field is not
    /// ready when the hold's limit passes, and the focused pane's terminal still has the keyboard. No close at all.
    @Test func aLineHeldForAPageBesideTheFocusedPaneGoesToNoTerminalWhenTheHoldLimitPasses() async throws {
        try await Self.withAHeldLine(besideTheFocusedPane: true) { held in
            held.passTheLimit()
            Self.expectNoKeyReachedTheOldView(held, "the hold's limit")
            // The count of the dropped keys is in the hold's log with the end's reason; the keys are not.
            #expect(held.input.log.contains { $0.hasPrefix("dropped 3 keys (limit)") }, "the hold's log does not count the dropped keys: \(held.input.log)")
            #expect(!held.input.log.contains { $0.hasPrefix("dropped") && $0.contains("ls") }, "the hold's log has the text of the dropped keys: \(held.input.log)")
            // The hold is over: the next key is the window's again.
            let next = try Self.keyDown("x", keyCode: 7, in: held.window)
            #expect(!held.input.capture(next, in: held.window), "a key typed after the limit was held: \(held.input.log)")
        }
    }

    /// The same limit, and a menu tracks at that moment (the menu bar's, or a right-click's). The keys of the line run
    /// again through the router, where the menu-pick hold (`KeyRouter.menuPickKeys`) takes each key-down while a menu
    /// tracks and sends it on after the menu's end. The line was typed before the menu: it comes to the hold's rule,
    /// which drops it. It does not wait in the menu-pick hold for the view that had the keyboard at the opening.
    @Test func aLineHeldForAPageBesideTheFocusedPaneGoesToNoTerminalWhenTheHoldLimitPassesWhileAMenuTracks() async throws {
        try await Self.withAHeldLine(besideTheFocusedPane: true) { held in
            let menu = NSMenu()
            // A key-down with no character: the menu-pick hold sends it on after the menu's end, and it types nothing.
            let control = try Self.keyDown("", keyCode: 255, in: held.window)
            // From the first notice to the last, nothing throws and no turn of the main actor ends: each other reader
            // of the process sees a menu of this test's own that began and ended with no key between.
            // global-notice-allow: the router's menu-pick hold (KeyRouter.menuPickKeys) reads the default center and takes no center; the object is this test's own menu
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            // The control: the router's menu-pick hold takes a key now. If not, the notice did not reach it, and the
            // asserts below are true for a wrong reason.
            let tracks = held.services.keyRouter.menuPickKeys.capture(control)
            if tracks { held.sentLater.owes(control) }
            held.passTheLimit()
            // global-notice-allow: the end of the same menu, in the same call as its begin (see above)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            #expect(tracks, "the menu's notice did not reach the router's menu-pick hold: this run proves nothing (hold log \(held.input.log))")
            Self.expectNoKeyReachedTheOldView(held, "the hold's limit while a menu tracks")
            #expect(held.input.log.contains { $0.hasPrefix("dropped 3 keys (limit)") }, "the hold's rule did not drop the 3 keys of the line while a menu tracked (the menu-pick hold took them, and sends them on after the menu's end): \(held.input.log)")
        }
    }

    /// A key typed while a menu tracks (the blink of a picked item) comes from the app's key path, not from a hold that
    /// runs it again: the router's menu-pick hold still takes it, BEFORE the New Tab hold (e7defd506a45). Only a key
    /// that the New Tab hold runs again (`heldBefore`) passes the menu-pick hold.
    @Test func aKeyTypedWhileAMenuTracksWaitsInTheMenuPickHoldAndNotInTheNewTabHold() async throws {
        try await Self.withAHeldLine(besideTheFocusedPane: true) { held in
            let router = held.services.keyRouter
            let holdKeys = { held.input.log.filter { $0.hasPrefix("hold key") }.count }
            // Key-downs with no character: the menu-pick hold sends its one on after the menu's end, and it types nothing.
            let before = try Self.keyDown("", keyCode: 255, in: held.window)
            let typed = try Self.keyDown("", keyCode: 255, in: held.window)
            // The control: with no menu, the New Tab hold takes such a key behind the line. If not, the count below
            // is true for a wrong reason.
            try #require(router.interceptKeyDown(before, in: held.window) && holdKeys() == 4, "with no menu the New Tab hold did not take a key with no character behind the line (\(holdKeys()) keys): this run proves nothing (hold log \(held.input.log))")
            let menu = NSMenu()
            // From the first notice to the last, nothing throws and no turn of the main actor ends (see the test above).
            // global-notice-allow: the router's menu-pick hold (KeyRouter.menuPickKeys) reads the default center and takes no center; the object is this test's own menu
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            let taken = router.interceptKeyDown(typed, in: held.window)
            let inTheNewTabHold = holdKeys()
            if taken, inTheNewTabHold == 4 { held.sentLater.owes(typed) } // the menu-pick hold has it
            // global-notice-allow: the end of the same menu, in the same call as its begin (see above)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            #expect(taken, "the router did not take a key typed while a menu tracked (hold log \(held.input.log))")
            #expect(inTheNewTabHold == 4, "a key typed while a menu tracked went into the New Tab hold (\(inTheNewTabHold) keys), not into the menu-pick hold that the router asks first: \(held.input.log)")
            held.passTheLimit()
            Self.expectNoKeyReachedTheOldView(held, "the hold's limit after a menu")
        }
    }

    /// The page's field gets READY while a menu tracks. The hold gives its keys to the field at once: they run again
    /// through the router with `heldBefore`, so the menu-pick hold does not take them. If it took them, the page got
    /// them only after the menu's end, behind each key typed in a pick's blink, and the replay did not judge the
    /// person's held Return in the page (the line did not run there).
    @Test func aLineHeldForAPageGoesToThePageAtItsReadinessWhileAMenuTracks() async throws {
        try await Self.withAHeldLine(besideTheFocusedPane: true) { held in
            let page = try #require(held.services.agentTabs.existingView(held.tab), "the fixture's page is gone")
            let gestures = page.model.transport.gestures
            // One more Return, as the HID system sends the person's (source pid 0): the page's gesture record takes
            // such a key in each build, and the replay of the hold gives it to the page that gets the key.
            let source = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
            source.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            let personsReturn = try #require(NSEvent(cgEvent: source))
            try #require(held.services.keyRouter.interceptKeyDown(personsReturn, in: held.window) && held.input.isHolding(in: held.window), "the hold did not take the person's Return: \(held.input.log)")
            try #require(!gestures.isAvailable, "the page has a gesture before the hold gave it a key: this run proves nothing")
            let menu = NSMenu()
            // A key-down with no character: the menu-pick hold sends it on after the menu's end, and it types nothing.
            let control = try Self.keyDown("", keyCode: 255, in: held.window)
            // From the first notice to the last, nothing throws and no turn of the main actor ends (see the test above).
            // global-notice-allow: the router's menu-pick hold (KeyRouter.menuPickKeys) reads the default center and takes no center; the object is this test's own menu
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            // The control: the router's menu-pick hold takes a key now. If not, the asserts below are true for a wrong reason.
            let tracks = held.services.keyRouter.menuPickKeys.capture(control)
            if tracks { held.sentLater.owes(control) }
            // The field reports ready, as the page does (`NewTabPage.open`).
            held.input.acknowledge(held.token, in: held.window)
            let reachedThePage = gestures.isAvailable
            let keyboard = held.window.firstResponder
            // global-notice-allow: the end of the same menu, in the same call as its begin (see above)
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            #expect(tracks, "the menu's notice did not reach the router's menu-pick hold: this run proves nothing (hold log \(held.input.log))")
            #expect(!held.input.isHolding(in: held.window) && held.input.log.contains { $0.hasPrefix("drained to field") }, "the hold did not give its keys to the ready field: \(held.input.log)")
            #expect(keyboard === page.webView, "the page's field did not get the keyboard at its readiness (first responder \(String(describing: keyboard))): this run proves nothing")
            #expect(reachedThePage, "the line held for the page did not go to the page at its readiness while a menu tracked (the menu-pick hold took the keys, and sends them on after the menu's end): \(held.input.log)")
            #expect(held.probe.typed.isEmpty, "the line went to the view that had the keyboard before the opening: \"\(held.probe.typed)\"")
        }
    }

    /// Cmd-N, a line typed for the new workspace's page, and the creation fails: the window still shows the
    /// old workspace and its terminal has the keyboard.
    @Test func aLineHeldForCmdNsPageGoesToNoTerminalWhenTheCreationFails() async throws {
        try await Self.withAHeldLine(incoming: true) { held in
            held.input.endIncoming(held.token, pageMade: false)
            Self.expectNoKeyReachedTheOldView(held, "Cmd-N's creation failed")
        }
    }

    /// Cmd-N whose page is not ready at the hold's limit: the old workspace's terminal still has the keyboard.
    @Test func aLineHeldForCmdNsPageGoesToNoTerminalWhenTheHoldLimitPasses() async throws {
        try await Self.withAHeldLine(incoming: true) { held in
            held.passTheLimit()
            Self.expectNoKeyReachedTheOldView(held, "the limit of Cmd-N's hold")
        }
    }

    /// The opening failed (`NewTabPage.open` cancels the hold): nothing took the keyboard.
    @Test func aLineHeldForANewTabPageGoesToNoTerminalWhenTheOpeningFails() async throws {
        try await Self.withAHeldLine { held in
            held.input.cancel(in: held.window)
            Self.expectNoKeyReachedTheOldView(held, "the opening failed")
        }
    }

    /// A second opening that is not a key (a click on +, a menu pick, a script) replaces the hold: the line
    /// waits for the newer page, and goes on in order when that hold ends.
    @Test func aLineHeldForANewTabPageWaitsForTheNewerPageWhenAnotherOpeningReplacesTheHold() async throws {
        try await Self.withAHeldLine { held in
            _ = try #require(held.input.begin(for: held.pane), "the second opening began no hold")
            #expect(held.probe.typed.isEmpty, "the second opening gave the line to the view that had the keyboard before the first: \"\(held.probe.typed)\" (hold log \(held.input.log))")
            #expect(held.input.isHolding(in: held.window), "the second opening holds no keys: \(held.input.log)")
            // The newer page takes the keyboard, and the hold ends: the line of the first hold is there, in order.
            let newer = try held.laterKeyboardView()
            held.passTheLimit()
            #expect(newer.typed == "ls\r", "the line of the replaced hold did not wait for the newer page: \"\(newer.typed)\" (hold log \(held.input.log))")
            Self.expectNoKeyReachedTheOldView(held, "a second opening")
        }
    }

    /// Cmd-N made a terminal, not a page (the creation's end, `pageMade: false`): the new terminal took the
    /// keyboard, and the line typed after Cmd-N is its line.
    @Test func aLineHeldForCmdNStillGoesToTheTerminalItsCreationMade() async throws {
        try await Self.withAHeldLine(incoming: true) { held in
            let made = try held.laterKeyboardView()
            held.input.endIncoming(held.token, pageMade: false)
            #expect(made.typed == "ls\r", "the line typed after Cmd-N did not reach the terminal the creation made: \"\(made.typed)\" (hold log \(held.input.log))")
            Self.expectNoKeyReachedTheOldView(held, "Cmd-N made a terminal")
        }
    }

    /// A script (the CLI, an agent) opens a New Tab page in a pane beside the one the person types in. The hold
    /// has what the person types in their terminal. The page never takes the keyboard (a script's opening may
    /// not move focus), so the hold ends at its limit: the person's terminal gets every key, in order. The drop
    /// rule is only for an opening of the person, whose keys are for the new page.
    @Test func aLineTypedWhileAScriptOpensAPageBesideTheFocusedPaneStillGoesToThePersonsTerminal() async throws {
        try await Self.withAHeldLine(besideTheFocusedPane: true, byScript: true) { held in
            held.passTheLimit()
            #expect(!held.input.isHolding(in: held.window), "the hold did not end at its limit: \(held.input.log)")
            #expect(held.probe.typed == "ls\r", "the line the person typed in their terminal while a script opened a page did not reach it in order: \"\(held.probe.typed)\" (hold log \(held.input.log))")
            #expect(!held.input.log.contains { $0.hasPrefix("dropped") }, "the hold of a script's opening dropped keys: \(held.input.log)")
        }
    }

    /// Two scripts open pages one after the other while the person types in their terminal: the first hold's
    /// keys are what the person typed in their terminal, so it gets them (at the replacement), and none is dropped.
    @Test func aLineTypedWhileTwoScriptsOpenPagesStillGoesToThePersonsTerminal() async throws {
        try await Self.withAHeldLine(besideTheFocusedPane: true, byScript: true) { held in
            _ = try #require(ActionRunScope.$current.withValue(Self.scriptRun) { held.input.begin(for: held.pane) }, "the second script's opening began no hold")
            #expect(held.input.isHolding(in: held.window), "the second script's opening holds no keys: \(held.input.log)")
            held.passTheLimit()
            #expect(!held.input.isHolding(in: held.window), "the hold did not end at its limit: \(held.input.log)")
            #expect(held.probe.typed == "ls\r", "the line the person typed in their terminal while two scripts opened pages did not reach it in order: \"\(held.probe.typed)\" (hold log \(held.input.log))")
            #expect(!held.input.log.contains { $0.hasPrefix("dropped") }, "a hold of a script's opening dropped keys: \(held.input.log)")
        }
    }

    /// The person clicks the + of a pane beside the focused one, and a script's opening in the same window
    /// replaces that hold before the person's first key. The line is still the person's line for the new page:
    /// at the limit it does not go to the terminal that had the keyboard at the person's opening.
    @Test func aLineTypedForThePersonsPageGoesToNoTerminalWhenAScriptsOpeningReplacedTheHoldFirst() async throws {
        try await Self.withAHeldLine(besideTheFocusedPane: true, thenAScriptOpens: true) { held in
            held.passTheLimit()
            Self.expectNoKeyReachedTheOldView(held, "the limit of a script's hold that replaced the person's")
        }
    }

    /// A script opens a page and the person types a line in their terminal; then the person opens a page (a click
    /// on +, a menu pick: not a key). The line was typed in the terminal, not for the person's page: it goes on to
    /// the terminal at the replacement, in order, and the person's hold starts with no keys.
    @Test func aLineTypedDuringAScriptsHoldGoesToThePersonsTerminalWhenThePersonThenOpensAPage() async throws {
        try await Self.withAHeldLine(besideTheFocusedPane: true, byScript: true) { held in
            _ = try #require(held.input.begin(for: held.pane), "the person's opening began no hold")
            #expect(held.probe.typed == "ls\r", "the line typed in the terminal during a script's hold did not reach it when the person opened a page: \"\(held.probe.typed)\" (hold log \(held.input.log))")
            #expect(held.input.isHolding(in: held.window), "the person's opening holds no keys: \(held.input.log)")
            held.passTheLimit()
            #expect(held.probe.typed == "ls\r", "the end of the person's hold changed what the terminal got: \"\(held.probe.typed)\" (hold log \(held.input.log))")
            #expect(!held.input.log.contains { $0.hasPrefix("dropped") }, "keys typed in the terminal during a script's hold were dropped: \(held.input.log)")
        }
    }

    /// The person's hold has a line for the new page, and a script's opening replaces it: the line is still the
    /// person's line for a page. It waits in the newer hold and, at its limit, does not go to the terminal that
    /// had the keyboard at the person's opening.
    @Test func aLineHeldForThePersonsPageGoesToNoTerminalWhenAScriptsOpeningReplacesTheHold() async throws {
        try await Self.withAHeldLine { held in
            _ = try #require(ActionRunScope.$current.withValue(Self.scriptRun) { held.input.begin(for: held.pane) }, "the script's opening began no hold")
            #expect(held.probe.typed.isEmpty, "the script's opening gave the person's line to the view that had the keyboard before: \"\(held.probe.typed)\" (hold log \(held.input.log))")
            held.passTheLimit()
            Self.expectNoKeyReachedTheOldView(held, "the limit of a script's hold that replaced the person's hold with keys")
        }
    }

    /// The person's page took the keyboard after the person's opening, and then a script's opening replaces the
    /// hold. The script's opening is not a moment that the person chose: what had the keyboard at the PERSON'S
    /// opening stays the owner. So the person's page, which took the keyboard after it, still gets the line.
    @Test func aLineHeldForThePersonsPageStillGoesToThatPageWhenAScriptsOpeningReplacesTheHoldAfterItTookTheKeyboard() async throws {
        try await Self.withAHeldLine { held in
            let page = try held.laterKeyboardView()
            _ = try #require(ActionRunScope.$current.withValue(Self.scriptRun) { held.input.begin(for: held.pane) }, "the script's opening began no hold")
            held.passTheLimit()
            #expect(page.typed == "ls\r", "the line for the person's page, which took the keyboard before a script's opening, did not reach it: \"\(page.typed)\" (hold log \(held.input.log))")
            Self.expectNoKeyReachedTheOldView(held, "the limit of a script's hold that replaced the person's hold after the page took the keyboard")
        }
    }

    /// The person presses Cmd-Shift-N in one window and types a line. The New Window hold takes the keys of EVERY
    /// window, so a script's opening in another window finds that hold and replaces it there. The line was typed in
    /// the first window for the new window's page: in the other window it reaches nothing. (What had the keyboard
    /// at the person's opening is a view of the first window. The keys of the newer hold run in the other window,
    /// so the owner there is what has the keyboard in that window.)
    @Test func aLineHeldForANewWindowsPageReachesNothingInAnotherWindowWhereAScriptOpensAPage() async throws {
        try await Self.withAHeldLine(newWindowHold: true) { held in
            let other = try #require(held.other, "the fixture made no second window")
            try #require(other.window.firstResponder === other.probe, "the keyboard left the second window's probe before the script's opening (first responder \(String(describing: other.window.firstResponder)))")
            _ = try #require(ActionRunScope.$current.withValue(Self.scriptRun) { held.input.begin(for: other.pane) }, "the script's opening in the other window began no hold")
            try #require(held.input.isHolding(in: other.window) && !held.input.isHolding(in: held.window), "the script's opening did not replace the New Window hold: \(held.input.log)")
            #expect(held.probe.typed.isEmpty && other.probe.typed.isEmpty, "the replacement gave the line on: first window \"\(held.probe.typed)\", other window \"\(other.probe.typed)\" (hold log \(held.input.log))")
            held.input.now = { ContinuousClock.now + .seconds(601) }
            held.input.flush(in: other.window)
            #expect(!held.input.isHolding(in: other.window), "the script's hold did not end at its limit: \(held.input.log)")
            #expect(other.probe.typed.isEmpty, "the line typed in the first window ran in the other window, where a script opened a page: \"\(other.probe.typed)\" (hold log \(held.input.log))")
            #expect(held.probe.typed.isEmpty, "the line typed for the new window's page went to the view that had the keyboard at the opening: \"\(held.probe.typed)\" (hold log \(held.input.log))")
            // The 3 keys came to the hold's rule in the other window, and the rule dropped them there: nothing else took them.
            #expect(held.input.log.contains { $0.hasPrefix("dropped 3 keys (limit)") }, "the hold's rule did not drop the 3 keys of the line in the other window: \(held.input.log)")
            // The control: after the hold's end, a key that runs again in the other window, by the path of the held keys and
            // with no hold's rule, MUST reach that window's probe, and no creation hold of that window may have keys. If not,
            // the asserts above are true for a wrong reason (something took the keys before the probe): the test fails.
            let creation = held.services.keyRouter.creationInputCoordinator
            #expect(!creation.isHolding(in: other.window), "a creation hold of the other window took keys: this run proves nothing (hold log \(held.input.log))")
            let before = other.probe.typed
            let control = try Self.keyDown("x", keyCode: 7, in: other.window)
            NewTabInputCoordinator.replay(control, held: control, in: other.window, router: held.services.keyRouter)
            let awaited = held.services.keyRouter.focus(for: other.window).0.flatMap { CreationInputCoordinator.awaitedContent($0) }
            let facts = "creation hold \(creation.isHolding(in: other.window)), awaited content \(String(describing: awaited)), pane shows \(other.pane.currentTabKey ?? "-"), first responder \(String(describing: other.window.firstResponder))"
            #expect(other.probe.typed == before + "x" && !creation.isHolding(in: other.window), "a key that runs again in the other window does not reach its probe: this run proves nothing (probe \"\(before)\" then \"\(other.probe.typed)\", \(facts))")
        }
    }

    /// The same for the rule's own type: a hold whose opening is not the person's records no owner and drops no key.
    @Test func aHoldOfAnOpeningThatIsNotThePersonsDropsNoKey() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = KeyProbe(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        try #require(window.contentView).addSubview(view)
        try #require(window.makeFirstResponder(view) && window.firstResponder === view, "the view did not take the keyboard")
        let keyboard = NewTabHoldKeyboard(in: window, persons: false)
        keyboard.endedUnready = true
        #expect(!keyboard.drops(keyFor: window.firstResponder), "a hold of a script's opening dropped a key of the view the person types in")
        #expect(keyboard.dropped == 0)
        let persons = NewTabHoldKeyboard(in: window)
        persons.endedUnready = true
        #expect(persons.drops(keyFor: window.firstResponder), "a hold of the person's opening did not drop a key for what had the keyboard at the opening")
    }

    /// The chord rule stays: keys typed ahead of Cmd-V go on first, in order, to the view that took the
    /// keyboard after the opening.
    @Test func aChordStillSendsTheHeldLineOnFirstToTheViewThatTookTheKeyboard() async throws {
        try await Self.withAHeldLine { held in
            let page = try held.laterKeyboardView()
            let paste = try Self.keyDown("v", keyCode: 9, flags: .command, in: held.window)
            #expect(!held.input.capture(paste, in: held.window), "the hold took the Cmd-V key itself")
            #expect(page.typed == "ls\r", "the keys typed ahead of Cmd-V did not go on in order: \"\(page.typed)\" (hold log \(held.input.log))")
            Self.expectNoKeyReachedTheOldView(held, "a chord")
        }
    }

    /// One field editor serves every text field of a window. A hold that opened while field A had the keyboard
    /// drops a held key that A would get, and gives on a key for field B, which took the keyboard after the
    /// opening through the same editor. (A test of the rule's own type: it has no form on a tree before the rule.)
    @Test func aFieldThatTookTheKeyboardAfterTheOpeningIsNotTheFieldThatHadItThroughTheSameFieldEditor() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let first = NSTextField(frame: CGRect(x: 10, y: 60, width: 200, height: 24))
        let second = NSTextField(frame: CGRect(x: 10, y: 20, width: 200, height: 24))
        let content = try #require(window.contentView)
        content.addSubview(first)
        content.addSubview(second)
        try #require(window.makeFirstResponder(first), "the first field did not take the keyboard")
        let editor = try #require(window.firstResponder as? NSTextView, "the first field has no field editor: \(String(describing: window.firstResponder))")
        try #require(editor.isFieldEditor && editor.delegate === first, "the window's first responder is not the first field's editor")

        let keyboard = NewTabHoldKeyboard(in: window)
        #expect(!keyboard.drops(keyFor: window.firstResponder), "a hold that has not ended dropped a key")
        keyboard.endedUnready = true
        #expect(keyboard.drops(keyFor: window.firstResponder), "a key for the field that had the keyboard at the opening was not dropped")

        try #require(window.makeFirstResponder(second), "the second field did not take the keyboard")
        let later = try #require(window.firstResponder as? NSTextView, "the second field has no field editor")
        try #require(later === editor && later.delegate === second, "the second field does not use the same field editor: this run proves nothing")
        #expect(!keyboard.drops(keyFor: window.firstResponder), "a key for a field that took the keyboard after the opening was dropped")
        #expect(keyboard.dropped == 1, "the count of the dropped keys is \(keyboard.dropped), not 1")
    }

    /// A terminal makes its surface view again at a replay. A view stands for what holds it (the stand-in rule), so
    /// the view made again in the same place is still what had the keyboard at the opening: its key is dropped.
    /// A view in another place gets its key. (A test of the rule's own type, as the one above.)
    @Test func aViewMadeAgainInTheSamePlaceIsStillWhatHadTheKeyboardAtTheOpening() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let otherHost = NSView(frame: CGRect(x: 120, y: 0, width: 100, height: 100))
        content.addSubview(host)
        content.addSubview(otherHost)
        let first = KeyProbe(frame: host.bounds)
        host.addSubview(first)
        try #require(window.makeFirstResponder(first) && window.firstResponder === first, "the first view did not take the keyboard")

        let keyboard = NewTabHoldKeyboard(in: window, standIn: { ($0 as? KeyProbe)?.superview })
        keyboard.endedUnready = true

        first.removeFromSuperview()
        let again = KeyProbe(frame: host.bounds)
        host.addSubview(again)
        try #require(window.makeFirstResponder(again) && window.firstResponder === again, "the view made again did not take the keyboard")
        #expect(keyboard.drops(keyFor: window.firstResponder), "a key for the view made again in the same place was not dropped")

        let elsewhere = KeyProbe(frame: otherHost.bounds)
        otherHost.addSubview(elsewhere)
        try #require(window.makeFirstResponder(elsewhere) && window.firstResponder === elsewhere, "the view in the other place did not take the keyboard")
        #expect(!keyboard.drops(keyFor: window.firstResponder), "a key for a view in another place was dropped")
        #expect(keyboard.dropped == 1, "the count of the dropped keys is \(keyboard.dropped), not 1")
    }
}
