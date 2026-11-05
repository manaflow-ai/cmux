import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextFocusUI
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextTerminal
import Foundation
import Testing

/// cmux-ad m12 (DAEMON TIMEOUT AUDIT, STATUS 11587, comment on #35075): a creation hold kept every key of the window
/// (but Cmd-W) until the creation's daemon reply. #35075 raised the request deadline from 2 s to 30 s, so a daemon that
/// does not answer held the person's keys up to 30 s on Cmd-N's room pin and on a new browser tab (about 10-12 s
/// before). The hold has its own bound now (``CreationInputBuffer/replyWaitBound``, never the transport's deadline):
/// at the bound the held keys go on, in typing order, to what has the keyboard; none is lost.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CreationHoldReplyBoundTests {
    /// Cmd-N for a terminal workspace whose daemon never answers (its room pin, then the create, never reply), with no move
    /// of the person's: at the hold's bound the keys typed after it go on in order to the terminal the person typed into at
    /// the press, also after a script moved the focus (input from the person goes before automation; lead on #35275: one
    /// fact, the person-intent target, no flag per input path). Base: they waited for the reply that never comes.
    /// `scriptThenTyping`: after the script's move the person types a second line during the hold; both lines run in the
    /// press-time terminal, in typing order (lead on #35275: a key typed then is no focus choice of the person's).
    @Test(arguments: [Move.noMove, .script, .scriptThenTyping])
    func keysTypedAfterCmdNWhoseDaemonNeverAnswersReachThePressTimeTerminalAtTheBound(_ move: Move) async throws {
        try await Self.cmdNNeverAnswered(then: move) { end, read in
            #expect(end == "replyBoundReached", "\(move): the hold ended \(end), not at its reply bound")
            // The last command's own output: with a second line, the read waits for it (round 11 read at `held`, before the
            // second command ran).
            let pressed = try await read(.pressed, move == .scriptThenTyping ? .alsoLine : .held)
            #expect(pressed.matched, "\(move): the press-time terminal did not run the typed line(s); its screen: \(pressed.screen.debugDescription)")
            let other = try await read(.other, .noHeld)
            #expect(!other.matched, "\(move): the line ran in the other terminal: \(other.screen.debugDescription)")
            guard move == .scriptThenTyping else { return }
            // Both commands ran as typed, in typing order: the first one's output `held` (a line typed while it ran is echoed
            // before it, as in any shell) on an earlier line than the second one's own output line, and no merged command.
            let lines = pressed.screen.components(separatedBy: "\n")
            let held = lines.firstIndex { $0.contains("held") }, also = lines.firstIndex { Self.isLine($0, "also") }
            #expect(held != nil && also != nil && held! < also!, "the two lines did not run in typing order: \(pressed.screen.debugDescription)")
            #expect(!pressed.screen.contains("heldecho"), "the two lines ran as one command: \(pressed.screen.debugDescription)")
            #expect(!other.screen.contains("also"), "the second line ran in the terminal the script focused")
        }
    }

    /// What moves the focus after the typed line and before the reply bound. The person's own moves are the ones that run
    /// while the hold keeps every key but Cmd-W (a Cmd-digit or a palette key typed then waits in the hold, in typing
    /// order): a click on another pane's view, a tab of the strip, a sidebar row or another text field; the Window menu's
    /// numbered workspace item; a palette pick. And a script's focus move, or its tab switch in the press-time terminal's
    /// pane. `backToPrevious`: the person clicked the other pane before the press and a script then put the focus on the
    /// press-time terminal; after the line the person clicks the other pane again (the same target as before the press).
    enum Move: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case noMove, paneClick, tabClick, workspaceClick, numberedWorkspaceItem, paletteWorkspacePick, script, scriptThenTyping
        case textFieldClick, backToPrevious, scriptHidesTab
        var testDescription: String { rawValue }
    }

    /// Each move of the person's before the bound, and each switch that hides the press-time terminal (whoever made it): at
    /// the bound the line typed for the new workspace runs in no terminal (dropped and logged), never in the press-time one
    /// the person left (reviews of #35275: a tab or pane click left the moved-on flag unset; a move that ends on the same
    /// person target as before the press, a click into a field or back onto the previous terminal, looked like no move;
    /// a script's tab switch left the terminal listed but hidden, and the held `rm -rf build` ran in a hidden shell).
    @Test(arguments: [Move.paneClick, .tabClick, .workspaceClick, .numberedWorkspaceItem, .paletteWorkspacePick, .textFieldClick,
                      .backToPrevious, .scriptHidesTab])
    func aMoveOfThePersonsBeforeTheBoundMeansTheLineRunsNowhere(_ move: Move) async throws {
        try await Self.cmdNNeverAnswered(then: move) { end, read in
            #expect(end == "replyBoundReached", "\(move): the hold ended \(end), not at its reply bound")
            for terminal in [Which.pressed, .other] {
                let screen = try await read(terminal, .noHeld)
                #expect(!screen.matched, "\(move): the line ran in the \(terminal) terminal: \(screen.screen.debugDescription)")
            }
        }
    }

    enum Which { case pressed, other }

    /// What a read of a terminal's screen waits for (``cmdNNeverAnswered(then:check:)``), on the daemon's output-woken wait
    /// with a 15 s deadline: the first line's output `held`, the second line's own output line `also` (the second command
    /// ran), or, for `held` that must not show, a marker command typed there after the hold ended: its output proves the
    /// shell ran everything typed before it, then the screen is read once (no fixed wait for an absence).
    enum Wait { case held, alsoLine, noHeld }

    /// Whether screen line `line` is `word` alone (a command's output line, not its echo).
    static func isLine(_ line: String, _ word: String) -> Bool { line.trimmingCharacters(in: .whitespacesAndNewlines) == word }

    typealias PaneTerminal = (pane: PaneController, tab: String, surface: SurfaceID)

    /// Two terminal panes (Cmd-D twice; the window's first pane may show an agent chat), and what `move` needs (a second tab
    /// in the first pane, a second workspace); the person's Cmd-N hold over the first terminal (`beginWorkspace(in:)`, as
    /// Cmd-N opens it for a person: a test window is never key, so `newTab` performed here has no source window and opens no
    /// person hold; PersonTerminalKeyboardClaimTests does the same), `echo hel''d` Return typed (it prints `held`, a word its
    /// command line does not contain), then `move`. The reply never
    /// comes: nothing resolves the ticket, as when the daemon never answers. `check` gets the hold's end reason (by name:
    /// the red build has no such case) and reads a terminal's screen until what it waits for shows (``Wait``).
    private static func cmdNNeverAnswered(then move: Move,
                                          check: (String, (Which, Wait) async throws -> (matched: Bool, screen: String)) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            let router = services.keyRouter
            let coordinator = router.creationInputCoordinator
            coordinator.replyWaitLimit = move == .scriptThenTyping ? .seconds(3) : .seconds(1) // room to type during the hold
            let controller = try #require(services.windows.active)
            let content = try #require(controller.workspaceContent)
            let window = try #require(content.layoutView.window)
            @MainActor func terminals() -> [PaneTerminal] {
                content.panes.values.compactMap { pane -> PaneTerminal? in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane, tab, model.surface)
                }
            }
            @MainActor func focus(_ terminal: PaneTerminal) async throws {
                PaneHandlers.focus(terminal.pane.layoutPaneID, in: content)
                try await PasswordManagerRouteTests.until({
                    content.focus.state.resolved == .terminal(pane: terminal.pane.paneKey, tab: terminal.tab)
                        && (window.firstResponder as? NSView)?.isDescendant(of: terminal.pane.view) == true
                }, report: { "the terminal pane does not have the keyboard: \(content.focus.state.resolved)" })
            }
            @MainActor func settled() async throws {
                try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, report: { "a set-up creation's hold did not end" })
            }
            var opensTerminal = ActionInvocation(origin: .user)
            opensTerminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            try await PasswordManagerRouteTests.until({ terminals().count == 1 }, report: { "no terminal pane after Cmd-D" })
            var pressed = try #require(terminals().first)
            try await focus(pressed)
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            try await PasswordManagerRouteTests.until({ terminals().count == 2 }, report: { "no second terminal pane after Cmd-D" })
            let other = try #require(terminals().first { $0.pane !== pressed.pane })
            try await settled()
            var secondTab: String?
            if move == .tabClick || move == .scriptHidesTab { // a second terminal tab in the first pane; the first one selected again
                let first = pressed.tab
                pressed.pane.newTerminalTab()
                try await PasswordManagerRouteTests.until({
                    pressed.pane.pane.tabs.contains { $0.id != first && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
                }, report: { "no second terminal tab in the first pane" })
                try await settled()
                secondTab = pressed.pane.pane.tabs.first { $0.id != first && $0.kind == .pty }?.id
                pressed.pane.handle(.select(CmuxNextTabs.TabID(first)))
                try await PasswordManagerRouteTests.until({ terminals().contains { $0.pane === pressed.pane && $0.tab == first } },
                                                          report: { "the first tab did not show again" })
                pressed = try #require(terminals().first { $0.pane === pressed.pane })
            }
            var secondWorkspace: String?
            if [.workspaceClick, .numberedWorkspaceItem, .paletteWorkspacePick].contains(move) { // a second workspace the window lists
                let created = try await connection.createWorkspace(name: "moved-to")
                let daemon = try #require(controller.content?.daemon)
                try await PasswordManagerRouteTests.until({ daemon.store.workspace(key: created.key) != nil }, report: { "the second workspace never listed" })
                secondWorkspace = daemon.store.workspace(key: created.key)?.id
            }
            if move == .backToPrevious { // the person's click in the other pane, before the press; then a script focuses the first
                controller.focus.responderDidChange(.content(pane: other.pane.paneKey), source: .mouse)
                try await PasswordManagerRouteTests.until({ content.focus.state.resolved == .terminal(pane: other.pane.paneKey, tab: other.tab) },
                                                          report: { "the click in the other pane did not move the focus: \(content.focus.state.resolved)" })
            }
            try await focus(pressed)
            let ticket = try #require(coordinator.beginWorkspace(in: controller), "a person's new workspace opened no key hold")
            @MainActor func typeLine(_ line: String) throws {
                for character in line {
                    let text = String(character)
                    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                              context: nil, characters: text, charactersIgnoringModifiers: text,
                                                              isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                    #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(text.debugDescription)")
                }
            }
            try typeLine("echo hel''d\r")
            switch move {
            case .noMove: break
            case .paneClick, .backToPrevious: // a click in the other pane's view: the window's report of its new first responder
                controller.focus.responderDidChange(.content(pane: other.pane.paneKey), source: .mouse)
            case .textFieldClick: // a click into another text field of the window (no terminal): the mouse responder report
                controller.focus.responderDidChange(.textField, source: .mouse)
            case .tabClick: // TabStripView's mouse-down select (selectOnPress), with the source its mouse-down dispatch gives
                let tab = try #require(secondTab)
                pressed.pane.select(CmuxNextTabs.TabID(tab), source: .mouse)
            case .workspaceClick: // a click on the sidebar row
                let workspace = try #require(secondWorkspace)
                controller.sidebar.handle(.select(WorkspaceID(workspace)))
            case .numberedWorkspaceItem: // the Window menu's "Workspace N", Cmd-digit's action
                let workspace = try #require(secondWorkspace)
                let target = SidebarItem.workspace(WorkspaceID(workspace))
                let number = try #require((1...9).first { controller.sidebar.model.itemOrder.pick($0, SidebarNavigation.settings(services)) == target },
                                          "no numbered item names the second workspace: \(controller.sidebar.model.itemOrder.items)")
                #expect(services.registry.perform("selectWorkspaceByNumber", argument: "\(number)"))
            case .paletteWorkspacePick: // the palette's Go to Workspace (its Switch to Tab takes its person source from the key
                // or click that picked it inside the app's dispatch, which package tests do not run: the tab click covers it)
                let workspace = try #require(secondWorkspace)
                PaletteSourcesBridge.WorkspaceSource(services: services).selectWorkspace(id: workspace)
            case .script, .scriptThenTyping: // a script's focus move (the CLI): not the person's, still not the press-time target
                controller.focus.send(.focusPane(other.pane.paneKey, source: .cli))
            case .scriptHidesTab: // a script selects the second tab of the first pane: the press-time terminal is listed, hidden
                let tab = try #require(secondTab)
                pressed.pane.select(CmuxNextTabs.TabID(tab), source: .cli)
            }
            if move != .noMove { // the move ran: the keys' target, as a key typed now sees it, is not the press-time terminal
                try await PasswordManagerRouteTests.until({ controller.focus.currentState().typingTab != pressed.tab }, within: .seconds(4),
                                                          report: { "\(move) left the typing target on the press-time terminal" })
            }
            if move == .scriptThenTyping { // more keys typed during the hold, after the script's move
                #expect(coordinator.isHolding(in: window), "the hold ended before the second line")
                try typeLine("echo al''so\r")
            }
            // Within the bound and a margin, the hold ends.
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, within: .seconds(6),
                                                      report: { "the hold did not end at its reply bound" })
            let end = coordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "none"
            coordinator.resolve(ticket, landed: false, in: window) // a reply after the bound belongs to no hold
            // What the person sees: a command's own output (`held`, `also`: only its run prints them, its typed line has quotes).
            // The daemon's `wait-for` waits on the terminal's output with a deadline (woken by output, no sleep); it answers an
            // error at the deadline, and the test fails there with the screen. An absence is read once, after a marker command
            // typed into that terminal printed its output (`markP`/`markO`; its typed line has quotes): the shell ran what came
            // before it.
            let (pressedSurface, otherSurface) = (pressed.surface, other.surface)
            @MainActor func waitFor(_ pattern: String, on surface: SurfaceID) async -> (matched: Bool, screen: String) {
                if let reply = try? await connection.request(WaitForTextRequest(surface: surface, pattern: pattern, timeoutMs: 15_000),
                                                             timeout: .seconds(20)) {
                    return (reply.matched == true, reply.text)
                }
                return (false, (try? await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)))?.text ?? "unreadable")
            }
            try await check(end) { terminal, wait in
                let surface = terminal == .pressed ? pressedSurface : otherSurface
                switch wait {
                case .held: return await waitFor("held", on: surface)
                case .alsoLine: return await waitFor("(?m)^\\s*also\\s*$", on: surface)
                case .noHeld:
                    let marker = terminal == .pressed ? "P" : "O"
                    try await connection.send(surface, text: "echo mar''k\(marker)\r")
                    let settled = await waitFor("(?m)^\\s*mark\(marker)\\s*$", on: surface)
                    guard settled.matched else { return (true, "(the terminal never ran the marker) " + settled.screen) }
                    return (settled.screen.contains("held"), settled.screen)
                }
            }
        }
    }

    /// A new browser tab whose create the daemon never answers (``PaneBrowserTabOpener`` opens its hold with the stand-in's
    /// tab, and only the `new-frontend-browser-tab` reply resolves it): the keys typed meanwhile go on at the bound, in
    /// order, to what has the keyboard. Base: they waited for the keyed create to give up (30 s).
    @Test func keysTypedIntoANewBrowserTabWhoseDaemonNeverAnswersGoOnAtTheBound() async throws {
        var replayed: [(text: String, at: ContinuousClock.Instant)] = []
        try await PasswordManagerRouteTests.withApp(heldKeyReplay: { event, window, _ in
            replayed.append((event.characters ?? "", ContinuousClock.now))
            _ = window
        }) { services, _ in
            let router = services.keyRouter
            let coordinator = router.creationInputCoordinator
            coordinator.replyWaitLimit = .seconds(1)
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            let intent = controller.focus.beginIntent()
            // The stand-in's hold, as PaneBrowserTabOpener.openStandIn opens it; its reply never comes.
            let ticket = try #require(coordinator.begin(in: window, generation: intent, tab: "pending_tab_reply_bound"),
                                      "no hold opened for the new browser tab")
            let typed = ContinuousClock.now
            for character in "news" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: 0))
                #expect(coordinator.capture(event, in: window), "the hold did not keep \(text.debugDescription) while the reply waits")
            }
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) && replayed.count >= 4 }, within: .seconds(4),
                                                      report: { "after the bound: holding \(coordinator.isHolding(in: window)), replayed \(replayed.map(\.text))" })
            let wentOn = replayed.map(\.text)
            #expect(wentOn.joined() == "news", "the held keys went on out of order or not all: \(wentOn)")
            if let last = replayed.last { #expect(last.at - typed < .seconds(3), "the keys waited \(last.at - typed), past the bound") }
            coordinator.resolve(ticket, landed: false, in: window)
        }
    }
}

/// The hold's reply bound itself (no daemon).
@MainActor @Suite struct CreationHoldReplyBoundRuleTests {
    /// The bound is its own constant, no larger than the hold's pre-#35075 worst case (a 10 s late-reply budget plus one
    /// 2 s deadline), whatever the daemon request deadline is.
    @Test func theHoldsBoundIsItsOwnAndNoLargerThanBefore30sDeadlines() {
        #expect(CreationInputBuffer.replyWaitBound <= .seconds(12))
        #expect(CreationInputBuffer.replyWaitBound < DaemonConnection.defaultRequestTimeout)
    }

    /// A creation waiting for its reply keeps the window's keys only within the bound, counted from its own start.
    @Test func aPendingCreationKeepsKeysOnlyWithinTheReplyBound() {
        let letter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)!
        let buffer = CreationInputBuffer(began: .now)
        _ = buffer.open(generation: 1, at: .now - .seconds(11))
        #expect(buffer.hasPendingCreation)
        #expect(!buffer.holds(letter, limit: .seconds(2), expiring: true, closes: false, replyLimit: .seconds(10)),
                "a creation that waited 11 s for its reply still keeps the window's keys")
        let fresh = CreationInputBuffer(began: .now)
        _ = fresh.open(generation: 1)
        #expect(fresh.holds(letter, limit: .seconds(2), expiring: true, closes: false, replyLimit: .seconds(10)))
    }

    /// Cmd-N over terminal T and a typed command: at the reply bound the keys go to T only while the count of the person's
    /// focus choices is the one of the press and the window still shows T (lead on #35275: a script's move is no choice of
    /// the person's, so it costs the person no key). A choice of theirs (any, also one that ends where they were before the
    /// press), an unknown count, or T no longer shown keeps them out of T: counted, never typed.
    @Test(arguments: [(UInt64(7), true, true), (8, true, false), (nil, true, false), (7, false, false)] as [(UInt64?, Bool, Bool)])
    func aNewWorkspacesKeysGoToThePressTerminalOnlyWhileThePersonDidNotMove(_ personMoves: UInt64?, _ shown: Bool, _ typesIntoPress: Bool) throws {
        let buffer = CreationInputBuffer(began: .now)
        let press = CreationInputBuffer.HeldLane(tab: "press_tab", machine: nil)
        _ = buffer.open(generation: 1, newWorkspace: true, pressTerminal: press, personMoves: 7)
        var typed = 0
        for character in "rm -rf build\r" {
            let text = String(character)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                      context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
                                                      keyCode: text == "\r" ? 36 : 0))
            buffer.capture(event, focusedTab: press.tab, forNewWorkspace: true)
            typed += 1
        }
        buffer.endReplyWait(personMoves: personMoves, shows: { _ in shown })
        let keys = buffer.take(focused: nil, isShortcut: { _, _ in false })
        let intoPress = keys.flatMap(\.keys).filter { $0.lane == press }.count
        #expect(intoPress == (typesIntoPress ? typed : 0),
                "\(intoPress) of \(typed) key(s) went to the press terminal, person moves \(personMoves.map(String.init) ?? "unknown"), shown \(shown)")
        #expect(keys.flatMap(\.keys).count == intoPress, "keys went somewhere else: \(keys.flatMap(\.keys).map { $0.event.characters ?? "" })")
        #expect(buffer.untypedTerminalKeys == (typesIntoPress ? 0 : typed))
    }

    /// The lines typed for a new workspace before and after a script's focus move go on at the bound as ONE run typed into
    /// the press-time terminal, every key in typing order (round 11 of #35275: the second line looked split on the screen;
    /// it was the shell's echo of typeahead, and the test had read the screen before the second command ran). Also when that
    /// terminal still has its window's keyboard (`focused`): a run again as typed goes to the KEY window, which may be a
    /// floating panel (the Quick Agent Chat, the Chief pet's reply box) whose Return sends the line to an agent (review of
    /// #35275 at 2c4f80760117; dogfood v2.2.3).
    @Test(arguments: ["other_tab", "press_tab"])
    func thePressTerminalsHeldLinesGoOnAsOneRunInTypingOrder(_ focused: String) throws {
        let buffer = CreationInputBuffer(began: .now)
        let press = CreationInputBuffer.HeldLane(tab: "press_tab", machine: nil)
        _ = buffer.open(generation: 1, newWorkspace: true, pressTerminal: press, personMoves: 3)
        func capture(_ line: String, focusedTab: String) throws {
            for character in line {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
                                                          keyCode: text == "\r" ? 36 : 0))
                buffer.capture(event, focusedTab: focusedTab, forNewWorkspace: true)
            }
        }
        try capture("echo hel''d\r", focusedTab: press.tab)
        try capture("echo al''so\r", focusedTab: "other_tab") // after a script moved the focus; the person's claim holds
        buffer.endReplyWait(personMoves: 3, shows: { _ in true })
        let keys = buffer.take(focused: focused, isShortcut: { _, _ in false })
        #expect(keys.count == 1, "focused \(focused): the held keys went on in \(keys.count) runs")
        guard case .type(let events, let lane)? = keys.first else {
            Issue.record("focused \(focused): the held keys went on as no typed run: \(keys.first.map { "\($0)" } ?? "none")")
            return
        }
        #expect(lane == press)
        #expect(events.compactMap(\.characters).joined() == "echo hel''d\recho al''so\r", "the held keys went on out of order")
    }

    /// A close's read opened while a creation waits for its reply (a person's Cmd-W) does not restart that creation's reply
    /// bound: the creation's own 1 s bound still ends the hold (review of #35275: the close moved the creation's start and
    /// armed the bound again on its own ticket). A bound armed after the close is 60 s here, so only the creation's can end
    /// the hold within the wait, whatever the main thread's delays.
    @Test func aCloseDuringAPendingCreationKeepsTheCreationsReplyBound() async throws {
        let buffer = CreationInputBuffer(began: .now)
        buffer.replyWaitLimit = .seconds(1)
        let ended = BoundEnd()
        buffer.onBound = { _, bound in if bound == .reply { ended.byReply = true } }
        // The creation began 600 ms ago (`open(at:)`, the buffer's own hook for an earlier start), not a 600 ms sleep:
        // its wait is past 500 ms by construction, whatever the main thread's delays.
        _ = buffer.open(generation: 1, at: .now - .milliseconds(600))
        buffer.replyWaitLimit = .seconds(60)
        _ = buffer.openClose(closing: ["closing_tab"], machine: nil)
        #expect(buffer.waitedPastReplyBound(.milliseconds(500)), "the close restarted the creation's reply bound")
        let deadline = ContinuousClock.now + .seconds(5)
        while !ended.byReply, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ended.byReply, "the creation's 1 s reply bound did not end the hold once a close opened")
    }
}

/// Whether a hold's reply bound ended it (``CreationInputBuffer/onBound``).
@MainActor private final class BoundEnd { var byReply = false }
