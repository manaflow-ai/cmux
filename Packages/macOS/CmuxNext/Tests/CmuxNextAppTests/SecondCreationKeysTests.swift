import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// P0 1193 (tip watcher smoke on feat 5097a275a876, granted mini cmux18, 2 of 3 rounds): Cmd-D, a line typed at once,
/// Cmd-D again, a line typed at once. Both lines ran in the FIRST new terminal and the second new terminal got
/// nothing: while the second creation's focus was on its way, the first creation's early view still had the keyboard
/// and took the keys typed for the second one. A key belongs to the terminal the focus named when it was typed, and goes
/// only there (cmux-ad 10:48Z), in both directions:
/// - keys typed after the second creation began go to the second terminal, never to the first;
/// - keys held for the first creation go to the first terminal, never to the second, also when the second one gets the
///   keyboard first.
///
/// Two terminal panes of a real daemon stand in for the two creations' early views (their tabs are the creations'
/// tabs), so the result does not depend on when the daemon replies. A held key that runs again goes through
/// `NSApp.sendEvent`, which reaches only the key window, and a test window is never key: so each check reads where a
/// key went from the key router's answer (a key it does not hold goes on to the window's first responder) or from the
/// hold's end, which gives a lane whose terminal is not focused its keys by that terminal's input.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SecondCreationKeysTests {
    private struct Panes {
        let services: AppServices
        let connection: DaemonConnection
        let content: WorkspaceContentController
        let window: NSWindow
        /// The first creation's terminal (its early view) and the second's.
        let first: (pane: PaneController, tab: String, surface: SurfaceID)
        let second: (pane: PaneController, tab: String, surface: SurfaceID)
    }

    /// The app on a fresh daemon with two confirmed terminal panes side by side, the first left of the second (made by two
    /// splits: the test app's first pane is an agent chat, not a terminal); `body` runs with them.
    private static func withTwoTerminals(_ body: (Panes) async throws -> Void) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let first = try await splitToTerminal("first", services: services, content: content, window: window)
            let second = try await splitToTerminal("second", services: services, content: content, window: window)
            try await body(Panes(services: services, connection: connection, content: content, window: window, first: first, second: second))
        }
    }

    /// What a failed wait saw: each pane's tabs and shown tab, the focused pane, whether keys are held.
    private static func describe(_ content: WorkspaceContentController, _ window: NSWindow, _ services: AppServices) -> String {
        "panes \(content.panes.values.map { "\($0.pane.handle.rawValue): \($0.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" }) shows \($0.currentTabKey ?? "-")" }), "
            + "focused \(content.focusedPane?.paneKey ?? "-"), holding \(services.keyRouter.creationInputCoordinator.isHolding(in: window))"
    }

    /// `pane`'s confirmed terminal: its shown tab is a daemon PTY tab, its view a terminal.
    private static func shownTerminal(_ pane: PaneController) -> (pane: PaneController, tab: String, surface: SurfaceID)? {
        guard pane.pane.handle.rawValue < ProvisionalPane.firstHandle, let tab = pane.currentTabKey, case .terminal? = pane.currentContent,
              let model = pane.pane.tabs.first(where: { $0.id == tab && $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) })
        else { return nil }
        return (pane, tab, model.surface)
    }

    /// One split of the focused pane, to a terminal: the new confirmed terminal pane, focused with the keyboard, its hold
    /// ended.
    private static func splitToTerminal(_ name: String, services: AppServices, content: WorkspaceContentController,
                                        window: NSWindow) async throws -> (pane: PaneController, tab: String, surface: SurfaceID) {
        var terminal = ActionInvocation(origin: .user)
        terminal.opensTerminal = true
        let before = Set(content.panes.keys)
        let coordinator = services.keyRouter.creationInputCoordinator
        #expect(services.registry.perform("splitRight", invocation: terminal), "the \(name) split was refused: \(describe(content, window, services))")
        @MainActor func made() -> (pane: PaneController, tab: String, surface: SurfaceID)? {
            content.panes.filter { !before.contains($0.key) }.values.lazy.compactMap(shownTerminal).first
        }
        try await PinnedPageTests.until({ made() != nil && !coordinator.isHolding(in: window) }, report: {
            "waited for the \(name) split's confirmed terminal pane and the end of its hold; saw \(describe(content, window, services))"
        })
        let pane = try #require(made())
        try await focus(pane.pane, tab: pane.tab, content: content, window: window)
        return pane
    }

    /// Focus and the keyboard on `pane`'s terminal (the window's first responder is in its view).
    private static func focus(_ pane: PaneController, tab: String, in p: Panes) async throws {
        try await focus(pane, tab: tab, content: p.content, window: p.window)
    }

    private static func focus(_ pane: PaneController, tab: String, content: WorkspaceContentController, window: NSWindow) async throws {
        PaneHandlers.focus(pane.layoutPaneID, in: content)
        try await PinnedPageTests.until({
            content.focus.state.resolved == .terminal(pane: pane.paneKey, tab: tab)
                && (window.firstResponder as? NSView)?.isDescendant(of: pane.view) == true
        }, report: { "waited for the focus and the keyboard on terminal \(tab) of pane \(pane.paneKey); saw focus \(content.focus.state.resolved), first responder \(String(describing: window.firstResponder))" })
    }

    /// Types `text` through the app's key path (the key router, then the window, as `CmuxApplication.sendEvent` does);
    /// for each key, whether the key router held it.
    private static func type(_ text: String, in p: Panes) throws -> [Bool] {
        try text.map { character in
            let typed = String(character)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.window.windowNumber,
                                                      context: nil, characters: typed, charactersIgnoringModifiers: typed,
                                                      isARepeat: false, keyCode: typed == "\r" ? 36 : 0))
            let held = p.services.keyRouter.interceptKeyDown(event, in: p.window)
            if !held { p.window.sendEvent(event) }
            return held
        }
    }

    /// A key-down of `window`: `characters` with `flags`, physical key `keyCode`.
    private static func press(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, ignoring: String? = nil,
                              in p: Panes) throws -> Bool {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: p.window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                                                  isARepeat: false, keyCode: keyCode))
        let held = p.services.keyRouter.interceptKeyDown(event, in: p.window)
        if !held { p.window.sendEvent(event) }
        return held
    }

    /// Starts a reader in the focused terminal: it prints `R42x<nonce>` when it waits, then the hex of the next `count` bytes
    /// the terminal sends it, as `K42x<nonce><hex>K`.
    private static func startByteReader(nonce: String, count: Int = 4, on surface: SurfaceID, in p: Panes) async throws {
        let command = "stty raw -echo; echo R$((6*7))x\(nonce); b=$(head -c \(count) | od -An -tx1 | tr -d ' \\n'); stty sane; echo K$((6*7))x\(nonce)${b}K\r"
        _ = try Self.type(command, in: p)
        let started = try await Self.ran("R42x\(nonce)", on: surface, in: p)
        let screen = await Self.screen(surface, in: p)
        try #require(started, "the byte reader did not start: \(screen.suffix(300))")
    }

    private static func ran(_ marker: String, on surface: SurfaceID, in p: Panes) async throws -> Bool {
        let screen = try await p.connection.request(WaitForTextRequest(surface: surface, pattern: marker, timeoutMs: 20_000), timeout: .seconds(25))
        return screen.matched == true
    }

    private static func screen(_ surface: SurfaceID, in p: Panes) async -> String {
        (try? await p.connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)))?.text ?? "unreadable"
    }

    /// The smoke's step 23: the first creation's early view has the keyboard, the second creation began and its focus is
    /// on its way. A line typed now is the second terminal's: it waits for it and runs there, never in the first.
    @Test func keysTypedAfterTheSecondCreationBeganNeverGoToTheFirstTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = p.services.keyRouter.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(300)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            let firstCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(),
                                                               earlyTab: p.first.tab, tab: p.first.tab))
            // The second creation's focus is on its way to its tab (`awayFrom` keeps it from landing in this test, as the
            // new pane's focus had not landed yet in the smoke round).
            let generation = p.content.beginFocusIntent()
            p.content.focus.expect(.tab(p.second.tab), awayFrom: p.second.pane.paneKey, generation: generation)
            let secondCreation = try #require(coordinator.begin(in: p.window, generation: generation, earlyTab: p.second.tab, tab: p.second.tab))
            try #require(p.content.focus.state.resolved == .terminal(pane: p.first.pane.paneKey, tab: p.first.tab),
                         "the test needs the focus still on the first creation's terminal: \(p.content.focus.state.resolved)")

            let nonce = String(UInt32.random(in: 100_000...999_999))
            let held = try Self.type("echo d2x\(nonce)x$((6*7))\r", in: p)
            #expect(held.allSatisfy { $0 }, "keys typed for the second creation went on to the first creation's terminal: held \(held)")

            // Both creations replied; the second one's focus never landed: its keys still go to its own terminal.
            coordinator.resolve(firstCreation, landed: true, in: p.window)
            coordinator.resolve(secondCreation, landed: true, in: p.window)
            let inSecond = try await Self.ran("d2x\(nonce)x42", on: p.second.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            let second = await Self.screen(p.second.surface, in: p)
            #expect(inSecond, "the line typed for the second terminal did not run there: \(second.suffix(300))")
            #expect(!first.contains("d2x\(nonce)"), "the line typed for the second terminal reached the first one: \(first.suffix(300))")
        }
    }

    /// The other direction: keys held for the first creation (its early view did not have the keyboard yet) stay the
    /// first terminal's, when the second creation's terminal gets the keyboard first and the person types into it.
    @Test func keysHeldForTheFirstCreationNeverGoToTheSecondTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = p.services.keyRouter.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(300)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            // The first creation's focus is on its way, and its view does not have the keyboard yet.
            let firstGeneration = p.content.beginFocusIntent()
            p.content.focus.expect(.tab(p.first.tab), awayFrom: p.first.pane.paneKey, generation: firstGeneration)
            let firstCreation = try #require(coordinator.begin(in: p.window, generation: firstGeneration, earlyTab: p.first.tab, tab: p.first.tab))
            p.window.makeFirstResponder(nil)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            let heldFirst = try Self.type("echo d1x\(nonce)x$((6*7))\r", in: p)
            try #require(heldFirst.allSatisfy { $0 }, "the test needs the first creation's keys held: \(heldFirst)")

            // The second creation began (a click, not a key) and its terminal has the keyboard first.
            let secondCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(),
                                                                earlyTab: p.second.tab, tab: p.second.tab))
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            try #require(p.content.focus.state.expectation == nil,
                         "the test needs the focus landed on the second terminal: \(String(describing: p.content.focus.state.expectation))")
            let heldSecond = try Self.type("echo d2x\(nonce)x$((6*7))\r", in: p)
            #expect(heldSecond.allSatisfy { !$0 }, "keys typed into the second terminal, which has the keyboard, waited: \(heldSecond)")

            coordinator.resolve(firstCreation, landed: true, in: p.window)
            coordinator.resolve(secondCreation, landed: true, in: p.window)
            let inFirst = try await Self.ran("d1x\(nonce)x42", on: p.first.surface, in: p)
            let inSecond = try await Self.ran("d2x\(nonce)x42", on: p.second.surface, in: p)
            let second = await Self.screen(p.second.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            #expect(inFirst, "the line held for the first terminal did not run there: \(first.suffix(300))")
            #expect(inSecond, "the line typed into the second terminal did not run there: \(second.suffix(300))")
            #expect(!second.contains("d1x\(nonce)"), "the line held for the first terminal reached the second one: \(second.suffix(300))")
        }
    }

    /// Not only text: a held Ctrl-C and arrow key for the first creation reach the first terminal, encoded by its own
    /// surface (0x03, then its cursor-up sequence), when the second terminal has the keyboard; never the second terminal,
    /// where a Ctrl-C would stop another process.
    @Test func heldControlAndArrowKeysReachOnlyTheirOwnTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = p.services.keyRouter.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(300)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            try await Self.startByteReader(nonce: nonce, on: p.second.surface, in: p)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            try await Self.startByteReader(nonce: nonce, on: p.first.surface, in: p)

            // The first creation's focus is on its way and its view does not have the keyboard: the keys wait for it.
            let firstGeneration = p.content.beginFocusIntent()
            p.content.focus.expect(.tab(p.first.tab), awayFrom: p.first.pane.paneKey, generation: firstGeneration)
            let firstCreation = try #require(coordinator.begin(in: p.window, generation: firstGeneration, earlyTab: p.first.tab, tab: p.first.tab))
            p.window.makeFirstResponder(nil)
            let controlC = try Self.press("\u{3}", [.control], keyCode: 8, ignoring: "c", in: p)
            let up = try Self.press("\u{F700}", [.function, .numericPad], keyCode: 126, in: p)
            try #require(controlC && up, "the test needs Ctrl-C and Up held for the first creation: \(controlC), \(up)")

            // The second creation's terminal gets the keyboard first; then both creations reply.
            let secondCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(),
                                                                earlyTab: p.second.tab, tab: p.second.tab))
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            coordinator.resolve(firstCreation, landed: true, in: p.window)
            coordinator.resolve(secondCreation, landed: true, in: p.window)

            let inFirst = try await Self.ran("K42x\(nonce)03(1b5b41|1b4f41)K", on: p.first.surface, in: p)
            let second = await Self.screen(p.second.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            #expect(inFirst, "Ctrl-C and Up held for the first terminal did not reach it as 03 and cursor-up: \(first.suffix(300))")
            #expect(!second.contains("K42x\(nonce)"), "a key held for the first terminal reached the second one: \(second.suffix(300))")
        }
    }

    /// cmux-ad 11:15Z: Cmd-D, "ls", Up, Ctrl-C, Cmd-D, a line, all held for the first creation, whose terminal never got
    /// the keyboard. Each key goes to its own terminal at its place: "ls", Up and Ctrl-C to the first terminal (its own
    /// encoding: 6c 73, cursor-up, 03); the second Cmd-D runs as the app's split OF THE FIRST TERMINAL'S PANE (the pane it
    /// was typed for, never the focused one), at its place; the line after it goes to the pane that split made. Nothing
    /// of the first terminal's keys reaches the focused one.
    @Test func eachHeldKeyRunsAtItsPlaceInItsOwnTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let router = p.services.keyRouter
            let coordinator = router.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(300)
            // A test window is never key: run held keys as `CmuxApplication.sendEvent` does (the key router, then the window).
            coordinator.runKey = { event, window in if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) } }
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            try await Self.startByteReader(nonce: nonce, count: 6, on: p.second.surface, in: p)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            try await Self.startByteReader(nonce: nonce, count: 6, on: p.first.surface, in: p)

            let generation = p.content.beginFocusIntent()
            p.content.focus.expect(.tab(p.first.tab), awayFrom: p.first.pane.paneKey, generation: generation)
            let creation = try #require(coordinator.begin(in: p.window, generation: generation, earlyTab: p.first.tab, tab: p.first.tab))
            p.window.makeFirstResponder(nil)
            var held = try Self.type("ls", in: p)
            held.append(try Self.press("\u{F700}", [.function, .numericPad], keyCode: 126, in: p))
            held.append(try Self.press("\u{3}", [.control], keyCode: 8, ignoring: "c", in: p))
            held.append(try Self.press("d", [.command], keyCode: 2, in: p))
            held += try Self.type("echo n3x\(nonce)x$((6*7))\r", in: p)
            try #require(held.allSatisfy { $0 }, "the test needs every key held for the first creation: \(held)")

            // The hold ends with the keyboard on the second terminal.
            let before = Set(p.content.panes.keys)
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            coordinator.resolve(creation, landed: true, in: p.window)

            let inFirst = try await Self.ran("K42x\(nonce)6c731b(5b|4f)4103K", on: p.first.surface, in: p)
            @MainActor func split() -> SurfaceID? {
                p.content.panes.filter { !before.contains($0.key) }.values.compactMap { pane in
                    pane.pane.tabs.first { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }?.surface
                }.first
            }
            try await PinnedPageTests.until({ split() != nil }, report: { "the held Cmd-D made no pane: \(p.content.panes.count) panes" })
            let made = try #require(split())
            let inSplit = try await Self.ran("n3x\(nonce)x42", on: made, in: p)
            // The split is of the first terminal's pane: the new pane lies between the first and the second.
            @MainActor func left(_ pane: PaneController?) -> CGFloat? { pane.map { $0.view.convert($0.view.bounds, to: nil).minX } }
            let madePane = p.content.panes.values.first { $0.pane.tabs.contains { $0.surface == made } }
            try await PinnedPageTests.until({
                guard let a = left(p.first.pane), let m = left(madePane), let b = left(p.second.pane) else { return false }
                return a < m && m < b
            }, report: { "the held Cmd-D split another pane than the first terminal's: x \(String(describing: left(p.first.pane))), new \(String(describing: left(madePane))), second \(String(describing: left(p.second.pane)))" })
            let first = await Self.screen(p.first.surface, in: p)
            let second = await Self.screen(p.second.surface, in: p)
            #expect(inFirst, "ls, Up and Ctrl-C held for the first terminal did not reach it in order: \(first.suffix(300))")
            #expect(inSplit, "the line typed after the held Cmd-D did not run in the pane it made")
            #expect(!second.contains("K42x\(nonce)") && !second.contains("n3x\(nonce)x42"),
                    "a key held for another terminal reached the focused one: \(second.suffix(300))")
        }
    }

    /// cmux-ad 11:2xZ: keys held for the first creation reach its terminal also when the person switched to another
    /// workspace before the hold ended: that terminal is hidden, not closed, and nothing it was typed for is dropped
    /// or typed into the terminal the new workspace shows.
    @Test func heldKeysReachTheirTerminalAfterItsWorkspaceWasSwitchedAway() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = p.services.keyRouter.creationInputCoordinator
            coordinator.holdLimit = .milliseconds(300)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            let generation = p.content.beginFocusIntent()
            p.content.focus.expect(.tab(p.first.tab), awayFrom: p.first.pane.paneKey, generation: generation)
            let creation = try #require(coordinator.begin(in: p.window, generation: generation, earlyTab: p.first.tab, tab: p.first.tab))
            p.window.makeFirstResponder(nil)
            let held = try Self.type("echo h1x\(nonce)x$((6*7))\r", in: p)
            try #require(held.allSatisfy { $0 }, "the test needs the keys held for the first creation: \(held)")

            // Another workspace (Cmd-N), shown in this window, before the hold ends.
            #expect(p.services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ p.services.windows.active?.workspaceContent !== p.content },
                                            report: { "the window still shows the first workspace" })
            coordinator.resolve(creation, landed: true, in: p.window)
            let inFirst = try await Self.ran("h1x\(nonce)x42", on: p.first.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            #expect(inFirst, "the line held for the first terminal was lost when its workspace was switched away: \(first.suffix(300))")
        }
    }

    /// cmux-ad 11:2xZ: Cmd-D, a line typed for its terminal, Cmd-W, Cmd-D. A close key is never held (it acts at once
    /// on what it closes: `CreationInputBuffer.holds`), so Cmd-W closes the first new terminal, whose creation its
    /// focus is on its way to, and the keys typed for it go with it; the second Cmd-D then splits the pane that has the
    /// focus. Nothing typed for the closed terminal reaches another one.
    @Test func cmdWTypedForAPendingSplitClosesThatSplitOnly() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            // From a terminal (the test app's first pane is an agent chat, where Cmd-W may mean something else).
            let original = try await Self.splitToTerminal("starting", services: services, content: content, window: window).pane
            var terminal = ActionInvocation(origin: .user)
            terminal.opensTerminal = true
            let before = Set(content.panes.keys)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            // One main-actor turn up to the second Cmd-D: the first split's reply cannot have come.
            #expect(services.registry.perform("splitRight", invocation: terminal))
            let first = try #require(content.panes.first { !before.contains($0.key) }?.value, "the split shows no pane in its turn")
            // Its stand-in's tab (the pane shows it only in a later frame: `currentTabKey` is nil in this turn).
            let firstTab = try #require(first.pane.tabs.first?.id, "the split's stand-in has no tab: \(first.pane.tabs)")
            for character in "echo w9x\(nonce)" {
                let text = String(character)
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, characters: text, charactersIgnoringModifiers: text,
                                                          isARepeat: false, keyCode: 0))
                if !services.keyRouter.interceptKeyDown(event, in: window) { window.sendEvent(event) }
            }
            let close = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                                      isARepeat: false, keyCode: 13))
            if !services.keyRouter.interceptKeyDown(close, in: window) { window.sendEvent(close) }
            #expect(services.registry.perform("splitRight", invocation: terminal))

            @MainActor func confirmed() -> [PaneController] {
                content.panes.filter { !before.contains($0.key) }.map(\.value)
                    .filter { $0.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) } }
            }
            try await PinnedPageTests.until({ confirmed().count == 1 && !content.panes.values.contains { $0.currentTabKey == firstTab } },
                                            report: { "waited for 1 new terminal pane and the closed split gone; saw \(Self.describe(content, window, services))" })
            #expect(content.panes.values.contains { $0 === original }, "Cmd-W closed the pane it was not typed for")
            for pane in [original] + confirmed() {
                guard let surface = pane.pane.tabs.first(where: { $0.kind == .pty })?.surface else { continue }
                let text = (try? await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)))?.text ?? ""
                #expect(!text.contains("w9x\(nonce)"), "keys typed for the closed split reached another terminal: \(text.suffix(200))")
            }
        }
    }
}
