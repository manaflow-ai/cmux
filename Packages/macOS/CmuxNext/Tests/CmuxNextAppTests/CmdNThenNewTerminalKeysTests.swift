import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// P0 (STATUS 1729): Cmd-N, then Ctrl-` in the new workspace, then typing. Cmd-N's key hold
/// (`NewTabInputCoordinator.beginIncoming`) owns every key of its window until the new workspace's New Tab page
/// reports its field ready, at most 4 s. When the page was not ready yet at the person's Ctrl-`, the new terminal tab
/// hid the page, and the hold went on taking every key of the window: the line typed into the new terminal
/// (debug.key: handled_by "app", the router's last action still newSurface) waited for the hold's limit and did not
/// run when the person typed it. 6 of 14 rounds of the journey focus-switch-corner-drag, on fix and base builds.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdNThenNewTerminalKeysTests {
    @Test func aLineTypedAfterCtrlBacktickInCmdNsWorkspaceRunsInTheNewTerminal() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let focused = try #require(content.focusedPane, "the workspace has no focused pane")
            let router = services.keyRouter
            let input = router.newTabInputCoordinator
            // The person types within Cmd-N's bound (the journey typed 2.6-2.9 s after Cmd-N, under its 4 s): the bound
            // never decides this test.
            input.incomingHoldLimit = .seconds(600)
            input.scheduleDeadline = { _, _ in Task {} }
            // Cmd-N's hold, as `AppActions.newWorkspace` begins it for a person's Cmd-N onto the New Tab page; the page is
            // made (its token claimed) and has not reported its field ready yet.
            let token = try #require(input.beginIncoming(in: window), "Cmd-N's key hold did not begin")
            input.attachIncoming(token)
            #expect(input.isHolding(in: window))

            // The person's Ctrl-` (New Terminal Tab) in that workspace.
            let before = Set(focused.pane.tabs.map(\.surface))
            #expect(services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user)))
            // The new terminal took the window's keys: the New Tab page's hold no longer owns them.
            #expect(!input.isHolding(in: window), "Cmd-N's New Tab hold still owns the window's keys after the person's Ctrl-` made a terminal")

            @MainActor func made() -> TabModel? {
                guard let selected = focused.selectedTab, selected.kind == .pty, !before.contains(selected.surface),
                      !ProvisionalTab.isProvisional(surface: selected.surface) else { return nil }
                return selected
            }
            try await PinnedPageTests.until({ made() != nil }, report: {
                "pane tabs \(focused.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" }), selected \(String(describing: focused.selectedTab?.surface.rawValue))"
            })
            let tab = try #require(made())
            try await PinnedPageTests.until({ (window.firstResponder as? NSView)?.isDescendant(of: focused.view) == true }, report: {
                "the window's first responder is \(String(describing: window.firstResponder)), not in the new terminal's pane"
            })
            // A key held by the creation hold is replayed through `NSApp.sendEvent`, which reaches only the key window, and a
            // test window is never key: type once the new terminal's own hold ended (as NewTerminalOnPendingSplitTests).
            let creation = router.creationInputCoordinator
            try await PinnedPageTests.until({ !creation.isHolding(in: window) }, report: { "the window's creation hold never ended" })

            // The person types a line into the new terminal, through the app's key path.
            let nonce = String(UInt32.random(in: 100_000...999_999))
            var held = 0
            for character in "echo cn\(nonce)t$((6*7))\r" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: text == "\r" ? 36 : 0))
                if router.interceptKeyDown(event, in: window) { held += 1 } else { window.sendEvent(event) }
            }
            #expect(held == 0, "\(held) typed key(s) were taken by a key hold instead of the new terminal (New Tab hold: \(input.isHolding(in: window)))")
            let screen = try? await connection.request(WaitForTextRequest(surface: tab.surface, pattern: "cn\(nonce)t42", timeoutMs: 10_000),
                                                       timeout: .seconds(15))
            #expect(screen?.matched == true, "the line typed into the new terminal did not run in it (keys taken by a hold: \(held))")
        }
    }
}
