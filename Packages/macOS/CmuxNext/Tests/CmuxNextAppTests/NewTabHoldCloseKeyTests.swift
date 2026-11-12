import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
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

    /// One workspace with one pane, or with two side by side; each pane has one tab.
    private static func tree(panes: Int) -> DaemonTree {
        let all = (1...panes).map { PaneSnapshot(id: PaneID(rawValue: UInt64($0)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "~")]) }
        let layout: LayoutNode = panes == 1 ? .leaf(all[0].id)
            : .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(all[0].id), b: .leaf(all[1].id))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: all)
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "hold-close-ws"), name: "hold", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "hold-close-ws"), index: 0)])
        return tree
    }

    private static func keyDown(_ character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
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
        var input: NewTabInputCoordinator { services.keyRouter.newTabInputCoordinator }

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
    private static func withAHeldLine(incoming: Bool = false, besideTheFocusedPane: Bool = false, _ body: (Held) throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let count = besideTheFocusedPane ? 2 : 1
        store.apply(snapshot: tree(panes: count))
        let controller = try #require(services.windows.openWindow(workspaces: ["hold-close-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "new-tab-hold-close-\(UUID().uuidString)")
        var pageKey: String?
        defer {
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
        let token = try #require(incoming ? input.beginIncoming(in: window) : input.begin(for: pane))
        if !incoming { input.didShow(in: window) }
        let line = [try keyDown("l", keyCode: 37, in: window), try keyDown("s", keyCode: 1, in: window), try keyDown("\r", keyCode: 36, in: window)]
        for event in line { try #require(router.interceptKeyDown(event, in: window), "the hold did not take a key of the line: \(input.log)") }
        try #require(input.isHolding(in: window) && probe.typed.isEmpty, "the line is not held: probe \"\(probe.typed)\", \(input.log)")
        try #require(window.firstResponder === probe, "the keyboard left the probe before the hold ended (first responder \(String(describing: window.firstResponder)))")

        try body(Held(services: services, window: window, pane: pane, tab: tab, probe: probe, token: token))
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
