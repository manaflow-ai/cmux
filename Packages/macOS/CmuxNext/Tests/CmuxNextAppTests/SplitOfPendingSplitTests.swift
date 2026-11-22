import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// P0 2026-10-30 ("at some points I can no longer make new terminals via Ctrl-` or Cmd-D"), bench-arms run
/// 02dcba2e1c9e447c7cad0594: in a quick pair of splits the second Cmd-D made no pane within 5 s, 12 of 12. The first
/// split's pane shows and takes focus in the key's frame (a stand-in, `ProvisionalPane`) before the daemon made it;
/// a second Cmd-D on it, while that reply is pending, must still give a second terminal pane that takes the keys.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SplitOfPendingSplitTests {
    /// A person's path (#28436): the line is typed at once after the second Cmd-D, while the creation hold of both
    /// splits waits. The hold keeps the keys and runs them again, in order, once the focus landed on the second pane;
    /// they run there. The app's replay is `NSApp.sendEvent`, to the key window a person types in; a test window is
    /// never key, so this replay runs each key as the app does (the key router, then the window) into the test's window.
    @Test func aLineTypedDuringTheHoldRunsInTheSecondPane() async throws {
        try await Self.typeDuringTheHold(replay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        })
    }

    /// The red form of the test above: a replay that drops the held keys, the shape of #28436 (`NSApp.sendEvent` with
    /// no key window delivers them nowhere). The check must fail on its own assertion, the line missing from the second
    /// pane; a pass here means the check no longer proves the keys arrive.
    @Test func aReplayThatDropsTheHeldKeysFailsTheCheck() async throws {
        try await withKnownIssue("the replay drops the held keys, so the typed line cannot run") {
            try await Self.typeDuringTheHold(replay: { _, _, _ in })
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("did not run in the second pane") }
        }
    }

    /// Two quick splits, the line typed at once during their creation hold, run again through `replay`; the line must
    /// run in the second split's own shell and the hold end because the focus landed.
    private static func typeDuringTheHold(replay: @escaping HeldKeyReplay) async throws {
        try await PinnedPageTests.withApp(heldKeyReplay: replay) { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let coordinator = services.keyRouter.creationInputCoordinator
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            var refusals: [String] = []
            let previous = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in refusals.append(reason); previous?(reason, quiet) }
            defer { services.registry.refusalObserver = previous }
            let mark = Self.journalMark()

            // One main-actor turn, no await: the first split is still a stand-in when the second Cmd-D comes.
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let first = try #require(content.panes.first { !before.contains($0.key) }?.value, "the first split shows no pane in its turn")
            #expect(first.pane.tabs.allSatisfy { ProvisionalTab.isProvisional(surface: $0.surface) }, "the first split already confirmed")
            PaneHandlers.focus(first.layoutPaneID, in: content)
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let nonce = String(UInt32.random(in: 100_000...999_999))
            var held = 0
            for character in "echo p0h\(nonce)h$((6*7))\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if coordinator.isHolding(in: window) { held += 1 }
                if !services.keyRouter.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
            #expect(held > 0, "no key was typed during the creation hold: the test does not cover it")

            @MainActor func confirmed() -> [PaneController] {
                content.panes.filter { !before.contains($0.key) }.map(\.value)
                    .filter { $0.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) } }
            }
            try await PinnedPageTests.until({ confirmed().count == 2 }, report: { "new confirmed terminal panes \(confirmed().count) of 2; refusals \(refusals)" })
            #expect(refusals.isEmpty, "a split was refused: \(refusals)")
            let second = try #require(confirmed().first { $0 !== first && $0.layoutPaneID != first.layoutPaneID })
            let surface = try #require(second.pane.tabs.first { $0.kind == .pty }?.surface)
            let screen: (matched: Bool, text: String)
            do {
                let found = try await connection.request(WaitForTextRequest(surface: surface, pattern: "p0h\(nonce)h42", timeoutMs: 20_000),
                                                         timeout: .seconds(25))
                screen = (found.matched == true, found.text)
            } catch {
                screen = (false, "wait-for failed: \(error)")
            }
            if !screen.matched {
                let report = await Self.missedLineReport(content: content, second: second, window: window, services: services,
                                                         connection: connection, since: mark)
                Issue.record("the line typed during the hold (\(held) keys held) did not run in the second pane: \(screen.text.suffix(300))\n\(report)")
            }
            #expect(coordinator.lastHoldEnd(in: window) == .focusLanded,
                    "the creation hold ended by \(String(describing: coordinator.lastHoldEnd(in: window))), not because the focus landed")
        }
    }

    @Test func aSecondSplitOnAPendingSplitsPaneMakesASecondPane() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            var refusals: [String] = []
            let previous = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in refusals.append(reason); previous?(reason, quiet) }
            defer { services.registry.refusalObserver = previous }
            let mark = Self.journalMark()

            // One main-actor turn, no await: the first split's reply cannot have come, and its stand-in has the focus.
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let first = try #require(content.panes.first { !before.contains($0.key) }?.value, "the first split shows no pane in its turn")
            #expect(first.pane.tabs.allSatisfy { ProvisionalTab.isProvisional(surface: $0.surface) }, "the first split already confirmed")
            PaneHandlers.focus(first.layoutPaneID, in: content)
            #expect(services.registry.perform("splitDown", invocation: terminal))

            @MainActor func confirmed() -> [PaneController] {
                content.panes.filter { !before.contains($0.key) }.map(\.value)
                    .filter { $0.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) } }
            }
            try await PinnedPageTests.until({ confirmed().count == 2 }, report: {
                "new confirmed terminal panes \(confirmed().count) of 2; panes \(content.panes.count); refusals \(refusals)"
            })
            #expect(refusals.isEmpty, "a split was refused: \(refusals)")
            let second = try #require(confirmed().first { $0 !== first && $0.layoutPaneID != first.layoutPaneID })
            try await PinnedPageTests.until({ content.focusedPane === second }, report: {
                "focused \(String(describing: content.focusedPane?.paneKey)), wanted the second split's pane \(second.paneKey)"
            })

            // It takes keys: a line typed through the app's key path (the key router, then the window, as
            // `CmuxApplication.sendEvent` does) runs in the second pane's own shell, as the daemon's screen shows.
            let window = try #require(content.layoutView.window)
            try await PinnedPageTests.until({ (window.firstResponder as? NSView)?.isDescendant(of: second.view) == true }, report: {
                "the window's first responder is \(String(describing: window.firstResponder)), not in the second split's pane"
            })
            let surface = try #require(second.pane.tabs.first { $0.kind == .pty }?.surface)
            // #28436: a key typed while the window's creation hold still waits is replayed later through `NSApp.sendEvent`,
            // which reaches only the key window, and a test window is never key (as in NewTerminalOnPendingSplitTests and
            // the journeys' `outwait_hold`). In 5 of 8 runs at 9adddb31f2f the hold was still open here and took all 24
            // keys; its replay reached no window. Type once the hold of both splits ended, because the focus landed.
            let coordinator = services.keyRouter.creationInputCoordinator
            try await PinnedPageTests.until({ !coordinator.isHolding(in: window) }, report: { "the window's creation hold never ended" })
            #expect(coordinator.lastHoldEnd(in: window) == .focusLanded,
                    "the creation hold ended by \(String(describing: coordinator.lastHoldEnd(in: window))), not because the focus landed")
            let nonce = String(UInt32.random(in: 100_000...999_999))
            var keyPath: [String] = ["typing: hold open \(coordinator.isHolding(in: window)), window key \(window.isKeyWindow), app \(type(of: NSApp!))"
                                     + ", second view surface \(services.cache.existingTerminal(second.pane.tabs.first { $0.kind == .pty }?.id ?? "")?.session.diagnostics.hasSurface == true)"]
            for character in "echo p0x\(nonce)x$((6*7))\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                let intercepted = services.keyRouter.interceptKeyDown(event, in: window)
                if !intercepted { window.sendEvent(event) }
                keyPath.append("\(text == "\r" ? "CR" : text): intercepted \(intercepted) holding \(coordinator.isHolding(in: window))")
            }
            let typedAt = ContinuousClock.now
            // #28436: the daemon's wait throws at its timeout; the miss must still say where the line went.
            let screen: (matched: Bool, text: String)
            do {
                let found = try await connection.request(WaitForTextRequest(surface: surface, pattern: "p0x\(nonce)x42", timeoutMs: 20_000),
                                                         timeout: .seconds(25))
                screen = (found.matched == true, found.text)
            } catch {
                screen = (false, "wait-for failed: \(error)")
            }
            if !screen.matched {
                let report = await Self.missedLineReport(content: content, second: second, window: window, services: services,
                                                         connection: connection, since: mark)
                    + "\nkey path (\(typedAt.duration(to: .now)) ago): " + keyPath.joined(separator: "; ")
                    + "\nafter: hold open \(coordinator.isHolding(in: window)), last end \(String(describing: coordinator.lastHoldEnd(in: window)))"
                Issue.record("the line typed after the second Cmd-D did not run in its pane: \(screen.text.suffix(300))\n\(report)")
            }
        }
    }
}
