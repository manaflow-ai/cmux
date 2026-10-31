import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// P0 close-then-type (STATUS 1333 and 1353; journey r3-after-switch round s3, cmux19, build a0f707a2): the journey
/// clicked into the right pane, pressed Cmd-W, and typed `echo r3fc-...` at once. The right pane closed, the left pane got
/// the keys, and its shell ran `cho r3fc-...`: the first key went into the closing terminal. A person's Cmd-W on a live
/// terminal first asks the daemon what the terminal runs (`TabCloseGuard`, the close warning), and until that read
/// answers, the closing terminal keeps the focus and the keyboard. A key typed after Cmd-W belongs to the terminal that
/// has the focus after the close: never the closing one, never dropped. When the warning shows and the person cancels,
/// the terminal stays, and the keys typed meanwhile are its keys.
///
/// The keys go through the app's key path (the key router, then the window's first responder, as
/// `CmuxApplication.sendEvent` does). A test window is never key, so a held key that runs again goes the same way here
/// (`CreationInputCoordinator.runKey`), not through `NSApp.sendEvent`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloseThenTypeKeysTests {
    private typealias Terminal = (pane: PaneController, tab: String, surface: SurfaceID)

    private struct Panes {
        let services: AppServices
        let connection: DaemonConnection
        let content: WorkspaceContentController
        let window: NSWindow
        let left: Terminal
        let right: Terminal
    }

    /// The app on a fresh daemon with two confirmed terminal panes side by side (Cmd-D), the right one focused.
    private static func withTwoTerminals(_ body: (Panes) async throws -> Void) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            // The window's first pane may show an agent chat, not a terminal: both terminals are new panes (Cmd-D twice,
            // the second split from the first new terminal, so it opens on its right).
            @MainActor func shown(_ pane: PaneController) -> Terminal? {
                guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey,
                      case .terminal? = pane.currentContent,
                      let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
                else { return nil }
                return (pane, tab, model.surface)
            }
            @MainActor func terminals() -> [Terminal] { content.panes.values.compactMap(shown) }
            @MainActor func panes() -> String {
                "panes \(content.panes.values.map { "\($0.pane.handle.rawValue): \($0.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" })" })"
            }
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await PinnedPageTests.until({ terminals().count == 1 }, report: { "waiting for the first split's terminal pane: \(panes())" })
            let first = try #require(terminals().first)
            PaneHandlers.focus(first.pane.layoutPaneID, in: content)
            try await PinnedPageTests.until({ content.focus.state.resolved == .terminal(pane: first.pane.paneKey, tab: first.tab) },
                                            report: { "waiting for the focus on the first terminal: \(content.focus.state.resolved)" })
            #expect(services.registry.perform("splitRight", invocation: terminal))
            try await PinnedPageTests.until({ terminals().count == 2 }, report: { "waiting for the second split's terminal pane: \(panes())" })
            let second = try #require(terminals().first { $0.pane !== first.pane })
            let window = try #require(content.layoutView.window)
            let coordinator = services.keyRouter.creationInputCoordinator
            try await PinnedPageTests.until({ !coordinator.isHolding(in: window) }, report: { "waiting for the splits' creation hold to end" })
            // A held key runs again through the same key path as a typed one (the test window is never key).
            let router = services.keyRouter
            coordinator.runKey = { [weak router] event, window in
                if router?.interceptKeyDown(event, in: window) != true { window.sendEvent(event) }
            }
            let p = Panes(services: services, connection: connection, content: content, window: window, left: first, right: second)
            try await Self.focus(p.right, in: p)
            try await body(p)
        }
    }

    /// Focus and the keyboard on `terminal` (the window's first responder is in its view).
    private static func focus(_ terminal: Terminal, in p: Panes) async throws {
        PaneHandlers.focus(terminal.pane.layoutPaneID, in: p.content)
        try await PinnedPageTests.until({
            p.content.focus.state.resolved == .terminal(pane: terminal.pane.paneKey, tab: terminal.tab)
                && (p.window.firstResponder as? NSView)?.isDescendant(of: terminal.pane.view) == true
        }, report: { "waiting for the focus and the keyboard on \(terminal.tab): focus \(p.content.focus.state.resolved), first responder \(String(describing: p.window.firstResponder))" })
    }

    /// A key-down of the window through the app's key path: the key router, then the window (its first responder).
    /// True when the key router took it.
    @discardableResult
    private static func press(_ characters: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0, in p: Panes) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        let taken = p.services.keyRouter.interceptKeyDown(event, in: p.window)
        if !taken { p.window.sendEvent(event) }
        return taken
    }

    private static func type(_ text: String, in p: Panes) throws {
        for character in text { try Self.press(String(character), keyCode: character == "\r" ? 36 : 0, in: p) }
    }

    /// Cmd-W, as the person presses it.
    private static func cmdW(in p: Panes) throws -> Bool { try Self.press("w", .command, keyCode: 13, in: p) }

    private static func shows(_ marker: String, on surface: SurfaceID, within milliseconds: Int = 20_000, in p: Panes) async throws -> Bool {
        let screen = try await p.connection.request(WaitForTextRequest(surface: surface, pattern: marker, timeoutMs: milliseconds),
                                                    timeout: .milliseconds(milliseconds + 5_000))
        return screen.matched == true
    }

    private static func screen(_ surface: SurfaceID, in p: Panes) async -> String {
        (try? await p.connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)))?.text ?? "unreadable"
    }

    /// The round s3 case: Cmd-W on the focused right terminal, a line typed at once (before the daemon answered the close
    /// warning's read). The right pane closes, and the whole line runs in the left terminal, its first key included.
    @Test func aLineTypedRightAfterCmdWRunsWholeInThePaneThatGetsTheFocus() async throws {
        try await Self.withTwoTerminals { p in
            let store = p.services.daemon.store
            let rightModel = try #require(store.tab(id: p.right.tab))
            try #require(TabCloseGuard.asks([rightModel], services: p.services), "the terminal close warning does not apply")

            #expect(try Self.cmdW(in: p), "the key router did not take Cmd-W")
            // As for a person: the close waits for the daemon's read first (the gap the first key fell into).
            try #require(TabCloseGuard.reading.contains(p.right.tab), "Cmd-W closed at once: the test needs the close warning's read")
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try Self.type("echo cw\(nonce)x$((6*7))\r", in: p)

            try await PinnedPageTests.until({ store.tab(surface: p.right.surface) == nil },
                                            report: { "waiting for the right terminal to close: reading \(TabCloseGuard.reading), asking \(TabCloseGuard.asking)" })
            let ran = try await Self.shows("cw\(nonce)x42", on: p.left.surface, in: p)
            let left = await Self.screen(p.left.surface, in: p)
            #expect(ran, "the line typed right after Cmd-W did not run whole in the left terminal (keys went into the closing terminal): \(left.suffix(400))")
            #expect(!left.contains("cho cw\(nonce)"), "the first key typed after Cmd-W was lost: \(left.suffix(400))")
            #expect(p.content.focus.state.resolved == .terminal(pane: p.left.pane.paneKey, tab: p.left.tab))
        }
    }

    /// The warning's case: the right terminal runs a program (`cat`), Cmd-W asks first, a line is typed at once, and the
    /// person cancels. The right terminal stays, and the keys typed meanwhile are its keys: never the left terminal's,
    /// never dropped.
    @Test func keysTypedWhileTheCloseWarningIsCancelledGoToTheTerminalThatStays() async throws {
        try await Self.withTwoTerminals { p in
            try Self.type("cat\r", in: p)
            var running: String?
            for _ in 0..<100 where running != "cat" {
                running = try? await p.connection.request(TerminalProcessInfoRequest(surface: p.right.surface), timeout: .seconds(1)).runningProgram
                if running != "cat" { try await Task.sleep(for: .milliseconds(100)) }
            }
            try #require(running == "cat", "cat never ran in the right terminal: \(String(describing: running))")
            let dialogs = CmuxDialogCenter.shared
            let warning = { dialogs.records.first { $0.spec.identifier == "cmux.dialog.confirmation" } }

            #expect(try Self.cmdW(in: p), "the key router did not take Cmd-W")
            try #require(TabCloseGuard.reading.contains(p.right.tab), "Cmd-W closed at once: the test needs the close warning's read")
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try Self.type("zq\(nonce)\r", in: p)

            try await PinnedPageTests.until({ warning() != nil }, report: { "waiting for the close warning: dialogs \(dialogs.records.map { $0.spec.identifier ?? "-" }), asking \(TabCloseGuard.asking)" })
            let shown = try #require(warning())
            #expect(dialogs.press(shown.id, button: "cancel"))
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(p.right.tab) }, report: { "waiting for the cancelled close to stop asking: asking \(TabCloseGuard.asking)" })

            // `cat` writes the line back after the terminal's own echo: two lines on the right, none on the left.
            _ = try await Self.shows("zq\(nonce)", on: p.right.surface, in: p)
            var right = ""
            for _ in 0..<100 {
                right = await Self.screen(p.right.surface, in: p)
                if right.components(separatedBy: "zq\(nonce)").count > 2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let left = await Self.screen(p.left.surface, in: p)
            #expect(right.components(separatedBy: "zq\(nonce)").count > 2,
                    "the keys typed while the warning asked did not reach the terminal that stays: \(right.suffix(400))")
            #expect(!left.contains("zq\(nonce)"), "keys typed for the terminal that stays went to the left terminal: \(left.suffix(400))")
            #expect(p.services.daemon.store.tab(surface: p.right.surface) != nil, "Cancel closed the right terminal")
            #expect(p.content.focus.state.resolved == .terminal(pane: p.right.pane.paneKey, tab: p.right.tab))
        }
    }
}
