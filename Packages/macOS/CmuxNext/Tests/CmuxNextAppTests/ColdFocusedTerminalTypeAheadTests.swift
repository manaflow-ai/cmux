import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// REOPEN-F4 (STATUS 4618; Lawrence, cmux-ad 02:35Z): a window that shows a workspace cold (a relaunch
/// restores it, a hibernated workspace comes back) gives the keyboard to its focused terminal, and a key
/// typed before that terminal's surface is shown waits for it and reaches it, in order, never dropped
/// and never another terminal's. On the feat tip the first key after a Cmd-Q keep + reopen was lost in
/// 10 of 15 cycles on cmux21: the focus named the restored terminal, its surface came 100-200 ms later
/// (one new surface per frame, another pane's first), and the key went to no view.
///
/// The test brings a workspace back cold with the frame's surface budget already spent, so no pane's
/// surface is shown in the turn the window shows it, and types a line in that same turn. The keys go
/// through the app's key path (the key router, then the window); a held key runs again the same way
/// (the test window is never key, so `NSApp.sendEvent` would deliver it nowhere).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ColdFocusedTerminalTypeAheadTests {
    private typealias Terminal = (pane: String, tab: String, surface: SurfaceID)

    /// A pane that spends the frame's one new surface (``ContentPresentationScheduler``).
    @MainActor private final class BudgetSpender: PresentablePane {
        var selectedContentIsAlive: Bool { false }
        var isFocusedInWorkspace: Bool { false }
        func showSelected() {}
    }

    @Test func aLineTypedAsAColdWorkspaceShowsReachesItsFocusedTerminalInOrder() async throws {
        try await Self.typeAsTheWorkspaceShowsCold(clearingFirst: false)
    }

    /// The first key is a terminal chord (Ctrl-L, which no app shortcut takes): it waits with the line and clears the
    /// screen before it runs (it was let through an empty hold and reached no view, review of #31707).
    @Test func aTerminalChordTypedFirstAsAColdWorkspaceShowsWaitsForItsTerminalToo() async throws {
        try await Self.typeAsTheWorkspaceShowsCold(clearingFirst: true)
    }

    /// `clearingFirst`: Ctrl-L before the line.
    private static func typeAsTheWorkspaceShowsCold(clearingFirst: Bool) async throws {
        try await PinnedPageTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            try await PinnedPageTests.until({ !services.windows.registry.isLaunching }, within: .seconds(60))
            let controller = try #require(services.windows.active)
            let window = try #require(controller.window)
            window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 760), display: true)

            // A workspace with two terminals side by side, the right one focused.
            let id = try #require(await services.windows.createWorkspace(into: controller.state.id))
            @MainActor func terminals() -> [Terminal] {
                guard controller.workspaceContent?.workspace.id == id, let content = controller.workspaceContent else { return [] }
                return content.panes.values.compactMap { pane in
                    guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
                          let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                    else { return nil }
                    return (pane.paneKey, tab, model.surface)
                }
            }
            @MainActor func describe() -> String {
                "workspace \(controller.workspaceContent?.workspace.id ?? "-") panes \(controller.workspaceContent?.panes.values.map { "\($0.paneKey): \($0.currentTabKey ?? "-")" } ?? [])"
                    + " focus \(controller.focus.state.resolved) first responder \(String(describing: window.firstResponder))"
            }
            try await PinnedPageTests.until({
                if controller.workspaceContent?.workspace.id != id { services.windows.show(workspaceID: id, in: controller.state) }
                return terminals().count == 1
            }, report: { "waiting for the workspace's terminal: \(describe())" })
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await PinnedPageTests.until({ terminals().count == 2 }, report: { "waiting for the split's terminal: \(describe())" })
            let content = try #require(controller.workspaceContent)
            let frames = Dictionary(uniqueKeysWithValues: terminals().map { ($0.pane, content.paneController(key: $0.pane)?.view.frame.minX ?? 0) })
            let ordered = terminals().sorted { frames[$0.pane, default: 0] < frames[$1.pane, default: 0] }
            let left = ordered[0], right = ordered[1]
            PaneHandlers.focus(try #require(content.paneController(key: right.pane)).layoutPaneID, in: content)
            try await PinnedPageTests.until({ controller.focus.state.resolved == .terminal(pane: right.pane, tab: right.tab)
                    && (window.firstResponder as? NSView)?.isDescendant(of: content.paneController(key: right.pane)?.view ?? NSView()) == true },
                report: { "waiting for the keyboard on the right terminal: \(describe())" })
            let coordinator = services.keyRouter.creationInputCoordinator
            try await PinnedPageTests.until({ !coordinator.isHolding(in: window) }, report: { "waiting for the split's creation hold to end" })
            // Both shells are ready before the line is typed.
            for shell in [left, right] {
                try await connection.send(shell.surface, text: "echo ready$((3*3))\r")
                let shown = try? await connection.request(WaitForTextRequest(surface: shell.surface, pattern: "ready9", timeoutMs: 20_000), timeout: .seconds(25))
                try #require(shown?.matched == true, "the shell of \(shell.tab) never answered")
            }

            // Another workspace, then this one hibernates: its panes and surfaces go, its focus stays remembered.
            let other = try #require(await services.windows.createWorkspace(into: controller.state.id))
            try await PinnedPageTests.until({
                if controller.workspaceContent?.workspace.id != other { services.windows.show(workspaceID: other, in: controller.state) }
                return controller.workspaceContent?.workspace.id == other && controller.workspaceContent?.panes.isEmpty == false
            }, report: { "waiting for the other workspace: \(describe())" })
            services.hibernateWorkspace(id)
            try await PinnedPageTests.until({ !services.cache.hasContent(for: left.tab) && !services.cache.hasContent(for: right.tab) },
                                            report: { "the hibernated workspace kept a surface: \(describe())" })

            // In one turn: the frame's surface budget is spent, the workspace shows cold, and the line is typed.
            let nonce = String(UInt32.random(in: 100_000...999_999))
            _ = services.presentation.showNow(BudgetSpender()) // false: another pane spent it already
            services.windows.show(workspaceID: id, in: controller.state)
            #expect(controller.workspaceContent?.workspace.id == id, "the window did not show the workspace in this turn")
            #expect(controller.focus.currentState().resolved == .terminal(pane: right.pane, tab: right.tab),
                    "the cold workspace's focus is not its remembered terminal: \(controller.focus.state.resolved)")
            #expect(!services.cache.hasContent(for: right.tab), "the focused terminal's surface already shows: the test types too late")
            if clearingFirst {
                let control = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
                                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                            context: nil, characters: "\u{0C}", charactersIgnoringModifiers: "l",
                                                            isARepeat: false, keyCode: 37))
                if !services.keyRouter.interceptKeyDown(control, in: window) { window.sendEvent(control) }
            }
            for character in "echo f4\(nonce)x$((6*7))\r" {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                                                          isARepeat: false, keyCode: character == "\r" ? 36 : 0))
                if !services.keyRouter.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }

            let ran = try? await connection.request(WaitForTextRequest(surface: right.surface, pattern: "f4\(nonce)x42", timeoutMs: 15_000),
                                                    timeout: .seconds(20))
            let rightScreen = (try? await connection.request(ReadScreenRequest(surface: right.surface), timeout: .seconds(5)))?.text ?? "unreadable"
            let leftScreen = (try? await connection.request(ReadScreenRequest(surface: left.surface), timeout: .seconds(5)))?.text ?? "unreadable"
            #expect(ran?.matched == true, "the line typed as the workspace showed never ran whole in its focused terminal: \(rightScreen)\n\(describe())")
            #expect(rightScreen.contains("echo f4\(nonce)x$((6*7))"), "the focused terminal's line is not the typed line, in order: \(rightScreen)")
            #expect(!leftScreen.contains("f4\(nonce)"), "keys typed for the focused terminal reached the other one: \(leftScreen)")
            if clearingFirst {
                #expect(!rightScreen.contains("ready9"), "the Ctrl-L typed first never reached the focused terminal (its screen was not cleared): \(rightScreen)")
            }
        }
    }
}
