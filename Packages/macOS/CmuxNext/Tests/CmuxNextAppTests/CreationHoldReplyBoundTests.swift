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
    @Test(arguments: [Move.noMove, .script])
    func keysTypedAfterCmdNWhoseDaemonNeverAnswersReachThePressTimeTerminalAtTheBound(_ move: Move) async throws {
        try await Self.cmdNNeverAnswered(then: move) { end, read in
            #expect(end == "replyBoundReached", "\(move): the hold ended \(end), not at its reply bound")
            let pressed = try await read(.pressed, true)
            #expect(pressed.ran, "\(move): the press-time terminal did not get the typed line in order; its screen: \(pressed.screen.debugDescription)")
            let other = try await read(.other, false)
            #expect(!other.ran, "\(move): the line ran in the other terminal: \(other.screen.debugDescription)")
        }
    }

    /// What moves the focus after the typed line and before the reply bound. The person's own moves are the ones that run
    /// while the hold keeps every key but Cmd-W (a Cmd-digit or a palette key typed then waits in the hold, in typing
    /// order): a click on another pane's view, a tab of the strip or a sidebar row; the Window menu's numbered workspace
    /// item; a palette pick. And a script's focus move.
    enum Move: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case noMove, paneClick, tabClick, workspaceClick, numberedWorkspaceItem, paletteWorkspacePick, script
        var testDescription: String { rawValue }
    }

    /// Each move of the person's before the bound changes their intent target, or hides the press-time terminal's workspace:
    /// at the bound the line typed for the new workspace runs in no terminal (dropped and logged), never in the press-time
    /// one the person left (review of #35275: a tab or pane click left the moved-on flag unset, and the held `rm -rf build`
    /// ran in a hidden shell).
    @Test(arguments: [Move.paneClick, .tabClick, .workspaceClick, .numberedWorkspaceItem, .paletteWorkspacePick])
    func aMoveOfThePersonsBeforeTheBoundMeansTheLineRunsNowhere(_ move: Move) async throws {
        try await Self.cmdNNeverAnswered(then: move) { end, read in
            #expect(end == "replyBoundReached", "\(move): the hold ended \(end), not at its reply bound")
            for terminal in [Which.pressed, .other] {
                let screen = try await read(terminal, false)
                #expect(!screen.ran, "\(move): the line ran in the \(terminal) terminal: \(screen.screen.debugDescription)")
            }
        }
    }

    enum Which { case pressed, other }

    typealias PaneTerminal = (pane: PaneController, tab: String, surface: SurfaceID)

    /// Two terminal panes (Cmd-D twice; the window's first pane may show an agent chat), and what `move` needs (a second tab
    /// in the first pane, a second workspace); the person's Cmd-N hold over the first terminal (`beginWorkspace(in:)`, as
    /// Cmd-N opens it for a person: a test window is never key, so `newTab` performed here has no source window and opens no
    /// person hold; PersonTerminalKeyboardClaimTests does the same), "echo held" Return typed, then `move`. The reply never
    /// comes: nothing resolves the ticket, as when the daemon never answers. `check` gets the hold's end reason (by name:
    /// the red build has no such case) and reads a terminal's screen: whether it ran the line, waiting up to 15 s for it
    /// to show (`expected` true) or 3 s for it not to (false).
    private static func cmdNNeverAnswered(then move: Move,
                                          check: (String, (Which, Bool) async throws -> (ran: Bool, screen: String)) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            let router = services.keyRouter
            let coordinator = router.creationInputCoordinator
            coordinator.replyWaitLimit = .seconds(1)
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
            if move == .tabClick { // a second terminal tab in the first pane; the first one selected again
                let first = pressed.tab
                pressed.pane.newTerminalTab()
                try await PasswordManagerRouteTests.until({
                    pressed.pane.pane.tabs.contains { $0.id != first && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
                }, report: { "no second terminal tab in the first pane" })
                try await settled()
                secondTab = pressed.pane.pane.tabs.first { $0.id != first && $0.kind == .pty }?.id
                pressed.pane.handle(.select(StripTabID(first)))
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
            try await focus(pressed)
            let ticket = try #require(coordinator.beginWorkspace(in: controller), "a person's new workspace opened no key hold")
            for character in "echo held\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(text.debugDescription)")
            }
            switch move {
            case .noMove: break
            case .paneClick: // a click in the other pane's view: the window's report of its new first responder, from a mouse-down
                controller.focus.responderDidChange(.content(pane: other.pane.paneKey), source: .mouse)
            case .tabClick: // TabStripView's mouse-down select (selectOnPress), with the source its mouse-down dispatch gives
                let tab = try #require(secondTab)
                pressed.pane.select(StripTabID(tab), source: .mouse)
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
            case .script: // a script's focus move (the CLI): not the person's, still not the press-time target
                controller.focus.send(.focusPane(other.pane.paneKey, source: .cli))
            }
            if move != .noMove { // the move ran: the keys' target, as a key typed now sees it, is not the press-time terminal
                try await PasswordManagerRouteTests.until({ controller.focus.currentState().typingTab != pressed.tab }, within: .seconds(4),
                                                          report: { "\(move) left the typing target on the press-time terminal" })
            }
            // Within the bound and a margin, the hold ends.
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, within: .seconds(4),
                                                      report: { "the hold did not end at its reply bound" })
            let end = coordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "none"
            coordinator.resolve(ticket, landed: false, in: window) // a reply after the bound belongs to no hold
            // What the person sees: whether a terminal shows the line and the shell's answer.
            func ran(_ text: String) -> Bool {
                text.contains("echo held") && text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "held" }
            }
            let (pressedSurface, otherSurface) = (pressed.surface, other.surface)
            try await check(end) { terminal, expected in
                let surface = terminal == .pressed ? pressedSurface : otherSurface
                var screen = ""
                let deadline = ContinuousClock.now + (expected ? .seconds(15) : .seconds(3))
                while ContinuousClock.now < deadline { // until it ran (a red when it must not) or the deadline
                    screen = (try? await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(2)).text) ?? screen
                    if ran(screen) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                return (ran(screen), screen)
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

    /// Cmd-N over terminal T and a typed command: at the reply bound the keys go to T only while T is still the focus core's
    /// typing target (the one fact the bound reads, lead order on #35275). Any other target (a click hid T, a script moved
    /// the focus, no terminal) keeps them out of T: counted, never typed. Base of the review: a left workspace's keys still
    /// went to T at the bound.
    @Test(arguments: [("press_tab", true), ("other_tab", false), (nil, false)] as [(String?, Bool)])
    func aNewWorkspacesKeysGoToThePressTerminalOnlyWhileItIsTheTypingTarget(_ typingTab: String?, _ typesIntoPress: Bool) throws {
        let buffer = CreationInputBuffer(began: .now)
        let press = CreationInputBuffer.HeldLane(tab: "press_tab", machine: nil)
        _ = buffer.open(generation: 1, newWorkspace: true, pressTerminal: press)
        var typed = 0
        for character in "rm -rf build\r" {
            let text = String(character)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                      context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false,
                                                      keyCode: text == "\r" ? 36 : 0))
            buffer.capture(event, focusedTab: press.tab, forNewWorkspace: true)
            typed += 1
        }
        buffer.endReplyWait(typingTab: typingTab)
        let keys = buffer.take(focused: nil, isShortcut: { _, _ in false })
        let intoPress = keys.flatMap(\.keys).filter { $0.lane == press }.count
        #expect(intoPress == (typesIntoPress ? typed : 0), "\(intoPress) of \(typed) key(s) went to the press terminal, typing target \(typingTab ?? "none")")
        #expect(keys.flatMap(\.keys).count == intoPress, "keys went somewhere else: \(keys.flatMap(\.keys).map { $0.event.characters ?? "" })")
        #expect(buffer.untypedTerminalKeys == (typesIntoPress ? 0 : typed))
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
        _ = buffer.open(generation: 1)
        try await Task.sleep(for: .milliseconds(600))
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
