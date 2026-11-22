import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// P0 2026-10-30, rule (b): a stand-in id never leaves for the daemon; a command that targets a pending pane waits for
/// its confirmation (the workspace's create chain, no timer) and then names the daemon's pane. Ctrl-` pressed on Cmd-D's
/// new pane before the daemon made it was sent with the stand-in's handle ("unknown pane"), and the new tab vanished.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTerminalOnPendingSplitTests {
    @Test func aNewTerminalTabOnAPendingSplitsPaneOpensThereAndTakesKeys() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            // One main-actor turn, no await: the split's reply cannot have come; its stand-in has the focus.
            #expect(services.registry.perform("splitDown", invocation: terminal))
            let first = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split shows no pane in its turn")
            #expect(first.pane.handle.rawValue >= ProvisionalPane.firstHandle, "the split already confirmed")
            PaneHandlers.focus(first.layoutPaneID, in: content)
            #expect(services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user)))

            @MainActor func ready() -> (PaneController, TabModel)? {
                for pane in content.panes.values where !before.contains(pane.layoutPaneID) && pane.pane.handle.rawValue < ProvisionalPane.firstHandle {
                    let terminals = pane.pane.tabs.filter { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }
                    if terminals.count == 2, let selected = pane.selectedTab, terminals.contains(where: { $0 === selected }) { return (pane, selected) }
                }
                return nil
            }
            try await PinnedPageTests.until({ ready() != nil }, report: {
                "panes \(content.panes.values.map { "\($0.pane.handle.rawValue): \($0.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" })" })"
            })
            let (pane, tab) = try #require(ready())
            #expect(tab === pane.pane.tabs.last, "the selected tab is not the new terminal tab")
            try await PinnedPageTests.until({ content.focusedPane === pane }, report: { "the split's pane lost the focus" })

            // It takes keys: a line typed through the app's key path runs in the new tab's own shell.
            let window = try #require(content.layoutView.window)
            try await PinnedPageTests.until({ (window.firstResponder as? NSView)?.isDescendant(of: pane.view) == true }, report: {
                "the window's first responder is \(String(describing: window.firstResponder)), not in the split's pane"
            })
            // A key typed while the window's creation hold still waits is replayed later through `NSApp.sendEvent`, which
            // reaches only the key window, and a test window is never key (the journeys' `outwait_hold`): type once the
            // hold of the split and the new tab ended.
            let coordinator = services.keyRouter.creationInputCoordinator
            try await PinnedPageTests.until({ !coordinator.isHolding(in: window) }, report: { "the window's creation hold never ended" })
            // ... and it ended because the focus landed on the new terminal, not at its 2 s bound (keys a person typed
            // meanwhile would have gone on that late): R-L5, its end is a signal.
            #expect(coordinator.lastHoldEnd(in: window) == .focusLanded,
                    "the creation hold ended by \(String(describing: coordinator.lastHoldEnd(in: window))), not because the focus landed")
            let responder = String(describing: window.firstResponder.map { type(of: $0) })
            let nonce = String(UInt32.random(in: 100_000...999_999))
            for character in "echo p0t\(nonce)t$((6*7))\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if !services.keyRouter.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
            let screen = try? await connection.request(WaitForTextRequest(surface: tab.surface, pattern: "p0t\(nonce)t42", timeoutMs: 20_000),
                                                       timeout: .seconds(25))
            if screen?.matched != true {
                // Where the typed line went instead: each terminal of the pane, and who had the keyboard.
                var screens: [String] = []
                for other in pane.pane.tabs where other.kind == .pty {
                    let text = (try? await connection.request(ReadScreenRequest(surface: other.surface), timeout: .seconds(5)))?.text ?? "unreadable"
                    screens.append("\(other.surface.rawValue)\(other === tab ? " (new)" : ""): \(text.suffix(200))")
                }
                Issue.record("the line typed into the new tab did not run in it; responder \(responder); holding \(coordinator.isHolding(in: window)); \(screens)")
            }
        }
    }
}
