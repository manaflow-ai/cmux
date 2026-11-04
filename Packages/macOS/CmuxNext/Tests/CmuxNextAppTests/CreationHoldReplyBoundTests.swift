import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
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
    /// The hold is opened as Cmd-N opens it for a person (`beginWorkspace(in:)`; a test window is never key, so `newTab`
    /// performed here has no source window and opens no person hold: PersonTerminalKeyboardClaimTests does the same), and
    /// its reply never comes: nothing resolves the ticket, as when the daemon never answers.
    @Test func keysTypedAfterCmdNWhoseDaemonNeverAnswersReachThePressTimeTerminalAtTheBound() async throws {
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
            // The person's Cmd-N for a terminal workspace, over the first terminal: its key hold and keyboard claim, and a
            // reply that never comes. Then a script's focus move to the other terminal (a new generation).
            let ticket = try #require(coordinator.beginWorkspace(in: controller), "a person's new workspace opened no key hold")
            for character in "echo held\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                #expect(router.interceptKeyDown(event, in: window), "the hold did not take \(text.debugDescription)")
            }
            controller.focus.send(.focusPane(other.pane.paneKey, source: .cli))
            // Within the bound and a margin, the hold ends at its reply bound.
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, within: .seconds(4),
                                                      report: { "the hold did not end at its reply bound" })
            let end = coordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "none" // by name: the red build has no such case
            #expect(end == "replyBoundReached", "the hold ended \(end), not at its reply bound")
            coordinator.resolve(ticket, landed: false, in: window) // a reply after the bound belongs to no hold
            // What the person sees: the terminal they typed into shows the line and the shell's answer; the other none of it.
            func ran(_ text: String) -> Bool {
                text.contains("echo held") && text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "held" }
            }
            var screen = ""
            let deadline = ContinuousClock.now + .seconds(15)
            while !ran(screen), ContinuousClock.now < deadline {
                screen = (try? await connection.request(ReadScreenRequest(surface: pressed.surface), timeout: .seconds(2)).text) ?? screen
                if !ran(screen) { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(ran(screen), "the press-time terminal did not get the typed line in order; its screen: \(screen.debugDescription)")
            let otherScreen = (try? await connection.request(ReadScreenRequest(surface: other.surface), timeout: .seconds(2)).text) ?? ""
            #expect(!otherScreen.contains("echo held"), "the line ran in the terminal a script focused: \(otherScreen.debugDescription)")
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
}
