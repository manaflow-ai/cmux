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
    /// after it wait at most the hold's bound, then go on in order to the terminal that has the keyboard (the window still
    /// shows it: the new workspace never came). Base: they waited for the reply that never comes.
    /// The hold is opened as Cmd-N opens it for a person (`beginWorkspace(in:)`; a test window is never key, so `newTab`
    /// performed here has no source window and opens no person hold: PersonTerminalKeyboardClaimTests does the same), and
    /// its reply never comes: nothing resolves the ticket, as when the daemon never answers.
    @Test func keysTypedAfterCmdNWhoseDaemonNeverAnswersReachTheFocusedTerminalAtTheBound() async throws {
        var replayed: [(text: String, at: ContinuousClock.Instant, terminalHadKeyboard: Bool)] = []
        var terminalView: NSView?
        try await PasswordManagerRouteTests.withApp(heldKeyReplay: { event, window, router in
            // A terminal has the keyboard: its view or a view inside it is the first responder (TerminalSession.hasKeyboard).
            let responder = window.firstResponder as? NSView
            let onTerminal = responder is TerminalSurfaceView || terminalView.map { responder?.isDescendant(of: $0) == true } == true
            replayed.append((event.characters ?? "", ContinuousClock.now, onTerminal))
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            let router = services.keyRouter
            let coordinator = router.creationInputCoordinator
            coordinator.replyWaitLimit = .seconds(1)
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            // The window's first pane may show an agent chat: the person types into a terminal pane (Cmd-D), focused.
            var opensTerminal = ActionInvocation(origin: .user)
            opensTerminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: opensTerminal))
            @MainActor func shownTerminal() -> (pane: PaneController, tab: String, surface: SurfaceID)? {
                content.panes.values.lazy.compactMap { pane -> (PaneController, String, SurfaceID)? in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane, tab, model.surface)
                }.first
            }
            try await PasswordManagerRouteTests.until({ shownTerminal() != nil }, report: { "no terminal pane after Cmd-D" })
            let shown = try #require(shownTerminal())
            let terminal = shown.surface
            terminalView = shown.pane.view
            PaneHandlers.focus(shown.pane.layoutPaneID, in: content)
            try await PasswordManagerRouteTests.until({
                content.focus.state.resolved == .terminal(pane: shown.pane.paneKey, tab: shown.tab)
                    && (window.firstResponder as? NSView)?.isDescendant(of: shown.pane.view) == true
            }, report: { "the terminal pane does not have the keyboard: \(content.focus.state.resolved)" })
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) }, report: { "the split's creation hold did not end" })
            // The person's Cmd-N for a terminal workspace: its key hold and keyboard claim, and a reply that never comes.
            let ticket = try #require(coordinator.beginWorkspace(in: services.windows.active), "a person's new workspace opened no key hold")
            let typed = ContinuousClock.now
            for character in "echo held\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
            // Within the bound and a margin, the hold ends and every key went on, in order, to the focused terminal.
            try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: window) && replayed.count >= 10 }, within: .seconds(4),
                                                      report: { "after the bound: holding \(coordinator.isHolding(in: window)), replayed \(replayed.map(\.text))" })
            let wentOn = replayed.map(\.text)
            #expect(wentOn.joined() == "echo held\r", "the held keys went on out of order or not all: \(wentOn)")
            let withoutTerminal = replayed.filter { !$0.terminalHadKeyboard }.map(\.text)
            #expect(withoutTerminal.isEmpty, "held keys went on while no terminal had the keyboard: \(withoutTerminal)")
            if let last = replayed.last { #expect(last.at - typed < .seconds(3), "the keys waited \(last.at - typed), past the bound") }
            let end = coordinator.lastHoldEnd(in: window).map { "\($0)" } ?? "none" // by name: the red build has no such case
            #expect(end == "replyBoundReached", "the hold ended \(end), not at its reply bound")
            coordinator.resolve(ticket, landed: false, in: window) // a reply after the bound belongs to no hold
            // What the person sees: the terminal that had the keyboard shows the line and the shell's answer.
            func ran(_ text: String) -> Bool {
                text.contains("echo held") && text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "held" }
            }
            var screen = ""
            let deadline = ContinuousClock.now + .seconds(15)
            while !ran(screen), ContinuousClock.now < deadline {
                screen = (try? await connection.request(ReadScreenRequest(surface: terminal), timeout: .seconds(2)).text) ?? screen
                if !ran(screen) { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(ran(screen), "the focused terminal did not get the typed line in order; its screen: \(screen.debugDescription)")
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
