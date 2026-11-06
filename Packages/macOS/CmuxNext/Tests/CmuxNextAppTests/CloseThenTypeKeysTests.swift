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
/// (the app's `heldKeyReplay`, set by `PinnedPageTests.withApp`), not through `NSApp.sendEvent`.
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
        // A held key runs again through the same key path as a typed one (the test window is never key, so
        // `NSApp.sendEvent` would deliver it nowhere).
        try await PinnedPageTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
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

    /// Whether `surface` shows `marker` within `milliseconds` (false on a timeout or a closed terminal, never a throw).
    private static func shows(_ marker: String, on surface: SurfaceID, within milliseconds: Int = 20_000, in p: Panes) async -> Bool {
        let screen = try? await p.connection.request(WaitForTextRequest(surface: surface, pattern: marker, timeoutMs: milliseconds),
                                                     timeout: .milliseconds(milliseconds + 5_000))
        return screen?.matched == true
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

            // The close warning's read is held (the debug seam), so the line is typed inside it in every run, as the
            // journey's first key was in round s3; the read answers only at the release below.
            let hold = p.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(try Self.cmdW(in: p), "the key router did not take Cmd-W")
            try #require(TabCloseGuard.reading.contains(p.right.tab), "Cmd-W closed at once: the test needs the close warning's read")
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try Self.type("echo cw\(nonce)x$((6*7))\r", in: p)

            // Where the keys went while the read waited: the closing terminal shows them at once if they went there.
            let inClosing = await Self.shows("cw\(nonce)", on: p.right.surface, within: 3_000, in: p)
            var closing = ""
            if inClosing { closing = await Self.screen(p.right.surface, in: p) }
            let resumed = hold.release()
            try #require(resumed == 1, "the close warning's read was not held (resumed \(resumed)): the line was not typed inside it")
            try await PinnedPageTests.until({ store.tab(surface: p.right.surface) == nil },
                                            report: { "waiting for the right terminal to close: reading \(TabCloseGuard.reading), asking \(TabCloseGuard.asking)" })
            let ran = await Self.shows("cw\(nonce)x42", on: p.left.surface, within: 10_000, in: p)
            let left = await Self.screen(p.left.surface, in: p)
            // The shell ran "cho cw..." (the "e" went elsewhere): "echo cw..." contains "cho cw" too, so look for the prompt's line.
            let firstKeyLost = left.contains("$ cho cw\(nonce)") || left.contains("command not found: cho")
            let outcome = inClosing ? "the line ran in the closing pane" : ran ? "the left pane ran it" :
                firstKeyLost ? "first key lost" : left.contains("cw\(nonce)") ? "the line reached the left pane incomplete" : "the line reached no pane"
            #expect(!inClosing, "the line ran in the closing pane (typed inside the close warning's read): \(closing.suffix(300))")
            #expect(!firstKeyLost, "first key lost: \(left.suffix(300))")
            #expect(ran, "the line did not run whole in the left pane (\(outcome)): \(left.suffix(400))")
            #expect(p.content.focus.state.resolved == .terminal(pane: p.left.pane.paneKey, tab: p.left.tab))
        }
    }

    /// Review of #29409: a second, quick Cmd-W (a double press, a key repeat) while the first close still reads ended the
    /// hold, and the keys held for the close ran into the closing terminal, then the next keys too. The second Cmd-W acts
    /// at once and the keys keep waiting: the whole line runs in the pane that gets the focus.
    @Test func aSecondCmdWDuringTheCloseReadKeepsTheKeysOutOfTheClosingTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let store = p.services.daemon.store
            let hold = p.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(try Self.cmdW(in: p), "the key router did not take Cmd-W")
            try #require(TabCloseGuard.reading.contains(p.right.tab), "Cmd-W closed at once: the test needs the close warning's read")
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try Self.type("echo dw\(nonce)", in: p)
            _ = try Self.cmdW(in: p) // the second, quick Cmd-W
            try Self.type("x$((6*7))\r", in: p)

            let inClosing = await Self.shows("dw\(nonce)", on: p.right.surface, within: 3_000, in: p)
            var closing = ""
            if inClosing { closing = await Self.screen(p.right.surface, in: p) }
            let resumed = hold.release()
            try #require(resumed >= 1, "the close warning's read was not held (resumed \(resumed)): the line was not typed inside it")
            try await PinnedPageTests.until({ store.tab(surface: p.right.surface) == nil },
                                            report: { "waiting for the right terminal to close: reading \(TabCloseGuard.reading), asking \(TabCloseGuard.asking)" })
            let ran = await Self.shows("dw\(nonce)x42", on: p.left.surface, within: 10_000, in: p)
            let left = await Self.screen(p.left.surface, in: p)
            #expect(!inClosing, "the line ran in the closing pane (a second Cmd-W during the close read let the held keys go): \(closing.suffix(300))")
            #expect(ran, "the line did not run whole in the left pane after two quick Cmd-Ws: \(left.suffix(400))")
        }
    }

    /// Review of #29409: the warning's Close path. The right terminal runs `cat`, Cmd-W, a line typed inside the held read,
    /// the warning shows and the person presses Close: the keys go to the pane that got the focus, never the closing one.
    @Test func keysTypedBeforeTheCloseWarningGoToThePaneThatGetsTheFocusOnClose() async throws {
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
            let hold = p.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(try Self.cmdW(in: p), "the key router did not take Cmd-W")
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try Self.type("echo wc\(nonce)x$((6*7))\r", in: p)
            // The read starts in a later main-actor turn: wait until it waits for the release, so the line was typed inside it.
            try await PinnedPageTests.until({ hold.held == 1 }, report: { "waiting for the close warning's read to be held: held \(hold.held), reading \(TabCloseGuard.reading)" })
            let resumed = hold.release()
            try #require(resumed == 1, "the close warning's read was not held (resumed \(resumed)): the line was not typed inside it")
            try await PinnedPageTests.until({ warning() != nil }, report: { "waiting for the close warning: dialogs \(dialogs.records.map { $0.spec.identifier ?? "-" })" })
            let shown = try #require(warning())
            #expect(dialogs.press(shown.id, button: DestructiveConfirmation.confirmID))
            try await PinnedPageTests.until({ p.services.daemon.store.tab(surface: p.right.surface) == nil },
                                            report: { "waiting for the right terminal to close after Close: asking \(TabCloseGuard.asking)" })
            let ran = await Self.shows("wc\(nonce)x42", on: p.left.surface, within: 10_000, in: p)
            let left = await Self.screen(p.left.surface, in: p)
            #expect(ran, "the keys typed before the warning did not run whole in the pane that got the focus on Close: \(left.suffix(400))")
        }
    }

    /// The warning's case: the right terminal runs a program (`cat`), Cmd-W asks first, a line is typed at once, and the
    /// person cancels. The right terminal stays, and the keys typed meanwhile are its keys: never the left terminal's,
    /// never dropped.
    @Test func keysTypedWhileTheCloseWarningIsCancelledGoToTheTerminalThatStays() async throws {
        try await Self.cancelledClose(focusElsewhereFirst: false)
    }

    /// The same, but the person clicks into the left pane while the warning shows, then cancels: the keys typed for the
    /// right terminal still go to it (by that terminal), never to the pane that has the focus now.
    @Test func keysOfACancelledCloseGoToTheTerminalThatStaysWhenTheFocusMovedAway() async throws {
        try await Self.cancelledClose(focusElsewhereFirst: true)
    }

    private static func cancelledClose(focusElsewhereFirst: Bool) async throws {
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
            if focusElsewhereFirst { PaneHandlers.focus(p.left.pane.layoutPaneID, in: p.content) }
            #expect(dialogs.press(shown.id, button: "cancel"))
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(p.right.tab) }, report: { "waiting for the cancelled close to stop asking: asking \(TabCloseGuard.asking)" })

            // `cat` writes the line back after the terminal's own echo: two lines on the right, none on the left.
            _ = await Self.shows("zq\(nonce)", on: p.right.surface, in: p)
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
            if !focusElsewhereFirst { #expect(p.content.focus.state.resolved == .terminal(pane: p.right.pane.paneKey, tab: p.right.tab)) }
        }
    }

    /// From the Cmd-D-after-Cmd-W P0 (STATUS 1644): Cmd-D, then Cmd-W at once cancels the split's creation, and the close
    /// list can still name the cancelled stand-in. No close hold may arm for a tab with no live terminal (a provisional
    /// stand-in has no read to wait for): a line typed after it runs whole in the focused live terminal.
    @Test func aCancelledStandInArmsNoCloseHoldAndTheNextLineRunsInTheLiveTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = p.services.keyRouter.creationInputCoordinator
            let before = Set(p.content.panes.keys)
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            #expect(p.services.registry.perform("splitRight", invocation: terminal))
            let standInPane = try #require(p.content.panes.first { !before.contains($0.key) }?.value, "the split shows no pane in its turn")
            let standIn = try #require(standInPane.pane.tabs.first, "the split's stand-in has no tab")
            try #require(ProvisionalTab.isProvisional(surface: standIn.surface), "the split replied in its own turn: no stand-in to test")
            // The guard itself: a stand-in never arms a close hold, whatever the focus names.
            #expect(coordinator.beginClose(of: [standIn], in: p.window) == nil, "a close hold armed for a cancelled stand-in")

            #expect(try Self.cmdW(in: p), "the key router did not take Cmd-W")
            try await PinnedPageTests.until({ !p.content.panes.values.contains { $0 === standInPane } },
                                            report: { "waiting for the cancelled split's pane to go: \(p.content.panes.count) panes" })
            try await PinnedPageTests.until({ !coordinator.isHolding(in: p.window) },
                                            report: { "waiting for no key hold after the cancelled split: last end \(String(describing: coordinator.lastHoldEnd(in: p.window)))" })
            let focused = try #require(p.content.focusedPane, "no focused pane after the cancelled split")
            let live = try #require(focused.pane.tabs.first { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) },
                                    "the focused pane after the cancelled split has no live terminal")
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try Self.type("echo sd\(nonce)x$((6*7))\r", in: p)
            let ran = await Self.shows("sd\(nonce)x42", on: live.surface, within: 10_000, in: p)
            let screen = await Self.screen(live.surface, in: p)
            #expect(ran, "the line typed after the cancelled split did not run whole in the focused live terminal: \(screen.suffix(400))")
            #expect(coordinator.lastHoldEnd(in: p.window) != .limitReached, "a key hold ran out its 2 s bound after the cancelled split")
        }
    }
}
