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
            let nonce = String(UInt32.random(in: 100_000...999_999))
            for character in "echo p0x\(nonce)x$((6*7))\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if !services.keyRouter.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
            let screen = try await connection.request(WaitForTextRequest(surface: surface, pattern: "p0x\(nonce)x42", timeoutMs: 20_000),
                                                      timeout: .seconds(25))
            #expect(screen.matched == true, "the line typed after the second Cmd-D did not run in its pane: \(screen.text.suffix(300))")
        }
    }
}
