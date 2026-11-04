import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
@testable import CmuxNextFocusUI
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
    /// Cmd-N for a terminal workspace whose daemon never answers (its room pin, then the create, never reply): the keys typed
    /// after it wait at most the hold's bound, then go on in order to the terminal the person typed into at the press, even
    /// when a script moved the focus to another terminal meanwhile (the person before automation: review of #35275). Base:
    /// they waited for the reply that never comes.
    @Test func keysTypedAfterCmdNWhoseDaemonNeverAnswersReachThePressTimeTerminalAtTheBound() async throws {
        try await Self.cmdNNeverAnswered(thenFocusMovesBy: .cli) { end, read in
            #expect(end == "replyBoundReached", "the hold ended \(end), not at its reply bound")
            let pressed = try await read(.pressed, true)
            #expect(pressed.ran, "the press-time terminal did not get the typed line in order; its screen: \(pressed.screen.debugDescription)")
            let other = try await read(.other, false)
            #expect(!other.ran, "the line ran in the terminal a script focused: \(other.screen.debugDescription)")
        }
    }

    /// The same Cmd-N, but the person moves on themselves (a click on another pane, as a click on a tab in the tab strip
    /// selects it on mouse down): at the bound the typed command runs nowhere, not in the press-time terminal they left
    /// (review of #35275 at b9d639ed46e7: the click ended the keyboard claim during its dispatch, so ``personMovedOn`` was
    /// never called, and the press lane typed `rm -rf build` into a hidden shell).
    @Test func keysTypedAfterCmdNRunNowhereAtTheBoundWhenThePersonMovedOn() async throws {
        try await Self.cmdNNeverAnswered(thenFocusMovesBy: .mouse) { end, read in
            #expect(end == "replyBoundReached", "the hold ended \(end), not at its reply bound")
            for terminal in [Which.pressed, .other] {
                let screen = try await read(terminal, false)
                #expect(!screen.ran, "the line ran in the \(terminal) terminal after the person moved on: \(screen.screen.debugDescription)")
            }
        }
    }

    enum Which { case pressed, other }

    /// Two terminal panes; the person's Cmd-N hold over the first (`beginWorkspace(in:)`, as Cmd-N opens it for a person: a
    /// test window is never key, so `newTab` performed here has no source window and opens no person hold;
    /// PersonTerminalKeyboardClaimTests does the same), "echo held" Return typed, then a focus move to the second terminal
    /// by `source`. The reply never comes: nothing resolves the ticket, as when the daemon never answers. `check` gets the
    /// hold's end reason (by name: the red build has no such case) and reads a terminal's screen: whether it ran the line,
    /// waiting up to 15 s for it to show (`expected` true) or 3 s for it not to (false).
    private static func cmdNNeverAnswered(thenFocusMovesBy source: FocusEvent.Source,
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
            // Two terminal panes (Cmd-D twice; the window's first pane may show an agent chat).
            @MainActor func terminals() -> [(pane: PaneController, tab: String, surface: SurfaceID)] {
                content.panes.values.compactMap { pane -> (PaneController, String, SurfaceID)? in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane, tab, model.surface)
                }
            }
            @MainActor func focus(_ terminal: (pane: PaneController, tab: String, surface: SurfaceID)) async throws {
                PaneHandlers.focus(terminal.pane.layoutPaneID, in: content)
                try await PasswordManagerRouteTests.until({
                    content.focus.state.resolved == .terminal(pane: terminal.pane.paneKey, tab: terminal.tab)
                        && (window.firstResponder as? NSView)?.isDescendant(of: terminal.pane.view) == true
                }, report: { "the terminal pane does not have the keyboard: \(content.focus.state.resolved)" })
            }
            var opensTerminal = ActionInvocation(origin: .user)
            opensTerminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            try await PasswordManagerRouteTests.until({ terminals().count == 1 }, report: { "no terminal pane after Cmd-D" })
            let pressed = try #require(terminals().first)
            try await focus(pressed)
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            try await PasswordManagerRouteTests.until({ terminals().count == 2 }, report: { "no second terminal pane after Cmd-D" })
            let other = try #require(terminals().first { $0.pane !== pressed.pane })
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, report: { "the splits' creation hold did not end" })
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
            controller.focus.send(.focusPane(other.pane.paneKey, source: source))
            // Within the bound and a margin, the hold ends.
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, within: .seconds(4),
                                                      report: { "the hold did not end at its reply bound" })
            let end = coordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "none"
            coordinator.resolve(ticket, landed: false, in: window) // a reply after the bound belongs to no hold
            // What the person sees: whether a terminal shows the line and the shell's answer.
            func ran(_ text: String) -> Bool {
                text.contains("echo held") && text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "held" }
            }
            try await check(end) { terminal, expected in
                let surface = terminal == .pressed ? pressed.surface : other.surface
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

    /// Cmd-N over terminal T, a typed command, then the person moves on (a click on another workspace hides T): at the reply
    /// bound the command never runs in T, a shell they left; its keys are counted, never typed (review of #35275 at
    /// 8deeb23ec4e5). Base: the bound gave T the left workspace's keys too.
    @Test func aNewWorkspaceThePersonLeftTypesNothingIntoThePressTerminalAtTheBound() throws {
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
        buffer.personMovedOn()
        buffer.endReplyWait(personStayed: true) // a stale claim: the move itself still keeps the keys out
        let keys = buffer.take(focused: nil, isShortcut: { _, _ in false })
        let intoPress = keys.flatMap(\.keys).filter { $0.lane == press }.count
        #expect(intoPress == 0, "\(intoPress) key(s) of the left workspace ran in the press terminal")
        #expect(keys.isEmpty, "the left workspace's keys went on: \(keys.flatMap(\.keys).map { $0.event.characters ?? "" })")
        #expect(buffer.untypedTerminalKeys == typed)
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
