import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTerminal
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
        try await PinnedPageTests.withApp(heldKeyReplay: Self.testWindowReplay) { services, connection in
            let content = try #require(services.windows.active?.workspaceContent)
            let window = try #require(content.layoutView.window)
            let first = try await splitToTerminal("first", services: services, content: content, window: window)
            let second = try await splitToTerminal("second", services: services, content: content, window: window)
            // The workspace's create chain is quiet before the test types: a create pressed later waits for it.
            let chain = await Self.settles(content.pendingCreate, within: .seconds(10))
            try #require(chain, "the setup's create chain did not end within 10 s after both panes showed: \(describe(content, window, services))")
            try await body(Panes(services: services, connection: connection, content: content, window: window, first: first, second: second))
        }
    }

    /// Whether `work` ends within `bound` (no work: true).
    private static func settles(_ work: ActionWork?, within bound: Duration) async -> Bool {
        guard let work else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await work.value; return true }
            group.addTask { try? await Task.sleep(for: bound); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
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

    /// Whether `marker` shows on `surface` within 20 s. A timeout is the answer "no" (the outcome a test checks), not
    /// an error.
    private static func ran(_ marker: String, on surface: SurfaceID, in p: Panes) async throws -> Bool {
        let screen = try? await p.connection.request(WaitForTextRequest(surface: surface, pattern: marker, timeoutMs: 20_000), timeout: .seconds(25))
        return screen?.matched == true
    }

    /// Held keys run again as `CmuxApplication.sendEvent` runs a key (the key router, then the window): a test window is
    /// never key, so `NSApp.sendEvent` would deliver them nowhere.
    private static let testWindowReplay: HeldKeyReplay = { event, window, router in
        if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
    }

    /// The creation hold of `p`'s app, with a short bound (its keys run again in the test window: ``testWindowReplay``).
    private static func replayInTestWindow(_ p: Panes) -> CreationInputCoordinator {
        let coordinator = p.services.keyRouter.creationInputCoordinator
        coordinator.holdLimit = .milliseconds(300)
        return coordinator
    }

    /// Whether the byte reader's result line (`K42x<nonce><hex>K`) on `surface` matches `pattern` within 20 s. It polls
    /// read-screen (returns at once, runs after the sends before it) and joins the screen's lines first: a narrow pane
    /// wraps the result line.
    private static func readerGot(_ pattern: String, on surface: SurfaceID, in p: Panes) async throws -> Bool {
        let regex = try Regex(pattern)
        let deadline = ContinuousClock.now + .seconds(20)
        repeat {
            if await screen(surface, in: p).replacingOccurrences(of: "\n", with: "").contains(regex) { return true }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return false
    }

    private static func screen(_ surface: SurfaceID, in p: Panes) async -> String {
        (try? await p.connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)))?.text ?? "unreadable"
    }

    /// The smoke's step 23: the first creation's early view has the keyboard, the second creation began and its focus is
    /// on its way. A line typed now is the second terminal's: it waits for it and runs there, never in the first.
    @Test func keysTypedAfterTheSecondCreationBeganNeverGoToTheFirstTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
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

            // Both creations replied; the second one's focus never landed: its keys still go to its own terminal.
            coordinator.resolve(firstCreation, landed: true, in: p.window)
            coordinator.resolve(secondCreation, landed: true, in: p.window)
            let inSecond = try await Self.ran("d2x\(nonce)x42", on: p.second.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            let second = await Self.screen(p.second.surface, in: p)
            // The outcome the person sees first, then how it came about.
            #expect(!first.contains("d2x\(nonce)"), "the line typed for the second terminal ran in the first one: \(first.suffix(300))")
            #expect(inSecond, "the line typed for the second terminal did not run there: \(second.suffix(300))")
            #expect(held.allSatisfy { $0 }, "keys typed for the second creation went on to the first creation's terminal: held \(held)")
        }
    }

    /// The other direction: keys held for the first creation (its early view did not have the keyboard yet) stay the
    /// first terminal's, when the second creation's terminal gets the keyboard first and the person types into it.
    @Test func keysHeldForTheFirstCreationNeverGoToTheSecondTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            // The first creation has no early view: the keys typed for it wait for it, on any build.
            let firstCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            let nonce = String(UInt32.random(in: 100_000...999_999))
            let heldFirst = try Self.type("echo d1x\(nonce)x$((6*7))\r", in: p)
            try #require(heldFirst.allSatisfy { $0 }, "the test needs the first creation's keys held: \(heldFirst)")

            // The second creation began (a click, not a key) and its terminal has the keyboard first.
            let secondCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(),
                                                                earlyTab: p.second.tab, tab: p.second.tab))
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            let heldSecond = try Self.type("echo d2x\(nonce)x$((6*7))\r", in: p)

            coordinator.resolve(firstCreation, landed: true, in: p.window)
            coordinator.resolve(secondCreation, landed: true, in: p.window)
            let inFirst = try await Self.ran("d1x\(nonce)x42", on: p.first.surface, in: p)
            let inSecond = try await Self.ran("d2x\(nonce)x42", on: p.second.surface, in: p)
            let second = await Self.screen(p.second.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            // The outcome the person sees first, then how it came about.
            #expect(!second.contains("d1x\(nonce)"), "the line held for the first terminal ran in the second one: \(second.suffix(300))")
            #expect(inFirst, "the line held for the first terminal did not run there: \(first.suffix(300))")
            #expect(inSecond, "the line typed into the second terminal did not run there: \(second.suffix(300))")
            #expect(heldSecond.allSatisfy { !$0 }, "keys typed into the second terminal, which has the keyboard, waited: \(heldSecond)")
        }
    }

    /// Not only text: a held Ctrl-C and arrow key for the first creation reach the first terminal, encoded by its own
    /// surface (0x03, then its cursor-up sequence), when the second terminal has the keyboard; never the second terminal,
    /// where a Ctrl-C would stop another process.
    @Test func heldControlAndArrowKeysReachOnlyTheirOwnTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            try await Self.startByteReader(nonce: nonce, on: p.second.surface, in: p)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            try await Self.startByteReader(nonce: nonce, on: p.first.surface, in: p)

            // The first creation has no early view: the keys typed for it wait for it, on any build.
            let firstCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            let controlC = try Self.press("\u{3}", [.control], keyCode: 8, ignoring: "c", in: p)
            let up = try Self.press("\u{F700}", [.function, .numericPad], keyCode: 126, in: p)
            try #require(controlC && up, "the test needs Ctrl-C and Up held for the first creation: \(controlC), \(up)")

            // The second creation's terminal gets the keyboard first; then both creations reply.
            let secondCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(),
                                                                earlyTab: p.second.tab, tab: p.second.tab))
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            coordinator.resolve(firstCreation, landed: true, in: p.window)
            coordinator.resolve(secondCreation, landed: true, in: p.window)

            let inFirst = try await Self.readerGot("K42x\(nonce)03(1b5b41|1b4f41)K", on: p.first.surface, in: p)
            let second = await Self.screen(p.second.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            #expect(!second.contains("K42x\(nonce)"), "a key held for the first terminal reached the second one: \(second.suffix(300))")
            #expect(inFirst, "Ctrl-C and Up held for the first terminal did not reach it as 03 and cursor-up: \(first.suffix(300))")
        }
    }

    /// cmux-ad 11:15Z: Cmd-D, "ls", Up, Ctrl-C, Cmd-D, a line, all held for the first creation, whose terminal never got
    /// the keyboard. Each key goes to its own terminal at its place: "ls", Up and Ctrl-C to the first terminal (its own
    /// encoding: 6c 73, cursor-up, 03); the second Cmd-D runs as the app's split OF THE FIRST TERMINAL'S PANE (the pane it
    /// was typed for, never the focused one), at its place; the line after it goes to the pane that split made. Nothing
    /// of the first terminal's keys reaches the focused one.
    @Test func eachHeldKeyRunsAtItsPlaceInItsOwnTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            try await Self.startByteReader(nonce: nonce, count: 6, on: p.second.surface, in: p)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            try await Self.startByteReader(nonce: nonce, count: 6, on: p.first.surface, in: p)

            // The first creation has no early view: the keys typed for it wait for it, on any build.
            let creation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
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

            let inFirst = try await Self.readerGot("K42x\(nonce)6c731b(5b|4f)4103K", on: p.first.surface, in: p)
            @MainActor func split() -> SurfaceID? {
                p.content.panes.filter { !before.contains($0.key) }.values.compactMap { pane in
                    pane.pane.tabs.first { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }?.surface
                }.first
            }
            try await PinnedPageTests.until({ split() != nil }, report: { "the held Cmd-D made no pane: \(p.content.panes.count) panes" })
            let made = try #require(split())
            let inSplit = try await Self.ran("n3x\(nonce)x42", on: made, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            let second = await Self.screen(p.second.surface, in: p)
            #expect(!second.contains("K42x\(nonce)") && !second.contains("n3x\(nonce)x42"),
                    "a key held for another terminal reached the focused one: \(second.suffix(300))")
            #expect(inFirst, "ls, Up and Ctrl-C held for the first terminal did not reach it in order: \(first.suffix(300))")
            #expect(inSplit, "the line typed after the held Cmd-D did not run in the pane it made")
            // The split is of the first terminal's pane: the new pane lies between the first and the second.
            @MainActor func left(_ pane: PaneController?) -> CGFloat? { pane.map { $0.view.convert($0.view.bounds, to: nil).minX } }
            let madePane = p.content.panes.values.first { $0.pane.tabs.contains { $0.surface == made } }
            try await PinnedPageTests.until({
                guard let a = left(p.first.pane), let m = left(madePane), let b = left(p.second.pane) else { return false }
                return a < m && m < b
            }, report: { "the held Cmd-D split another pane than the first terminal's: x \(String(describing: left(p.first.pane))), new \(String(describing: left(madePane))), second \(String(describing: left(p.second.pane)))" })
        }
    }

    /// cmux-ad 11:2xZ: keys held for the first creation reach its terminal also when the person switched to another
    /// workspace before the hold ended: that terminal is hidden, not closed, and nothing it was typed for is dropped
    /// or typed into the terminal the new workspace shows.
    @Test func heldKeysReachTheirTerminalAfterItsWorkspaceWasSwitchedAway() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            // The first creation has no early view: the keys typed for it wait for it, on any build.
            let creation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
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
    /// focus is on its way to, never the terminal it was typed from, and the keys typed for it go with it: nothing typed
    /// for the closed terminal reaches another one. Whether the second Cmd-D makes a pane is not this guard's question
    /// (on feat bcec3ce42ba it made none: the focus stayed on the closed stand-in; reported apart).
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
            let firstKey = first.paneKey
            try await PinnedPageTests.until({
                !content.panes.values.contains { $0.paneKey == firstKey || $0.currentTabKey == firstTab } && !services.keyRouter.creationInputCoordinator.isHolding(in: window)
            }, report: { "waited for the closed split \(firstKey) gone and no key hold; saw \(Self.describe(content, window, services))" })
            #expect(content.panes.values.contains { $0 === original }, "Cmd-W closed the pane it was not typed for")
            for pane in [original] + confirmed() {
                guard let surface = pane.pane.tabs.first(where: { $0.kind == .pty })?.surface else { continue }
                let text = (try? await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)))?.text ?? ""
                #expect(!text.contains("w9x\(nonce)"), "keys typed for the closed split reached another terminal: \(text.suffix(200))")
            }
        }
    }

    /// P0 1193 follow-up (review finding 1): a held Control shortcut typed for a terminal that is not focused at the
    /// hold's end runs as that shortcut on that terminal's pane, as a key press there would; it is never typed into the
    /// terminal as a byte (Ctrl-` is New Terminal Tab; before, only Command chords went through app dispatch).
    @Test func aHeldControlShortcutRunsOnTheTerminalItWasTypedFor() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            let firstTabs = p.first.pane.pane.tabs.count, secondTabs = p.second.pane.pane.tabs.count
            // The first creation has no early view: the key typed for it waits for it, on any build.
            let creation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            let held = try Self.press("`", [.control], keyCode: 50, in: p)
            try #require(held, "the test needs Ctrl-` held for the first creation")
            // The hold ends with the keyboard on the second terminal.
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            coordinator.resolve(creation, landed: true, in: p.window)
            try await PinnedPageTests.until({ p.first.pane.pane.tabs.count == firstTabs + 1 || p.second.pane.pane.tabs.count != secondTabs },
                                            within: .seconds(10), report: {
                "waited for a new tab in the first terminal's pane; saw first \(p.first.pane.pane.tabs.count) tabs (was \(firstTabs)), second \(p.second.pane.pane.tabs.count) (was \(secondTabs))"
            })
            #expect(p.second.pane.pane.tabs.count == secondTabs, "the held Ctrl-` opened a tab in the focused pane, not in the pane it was typed for")
            #expect(p.first.pane.pane.tabs.count == firstTabs + 1, "the held Ctrl-` did not run as New Terminal Tab in the first terminal's pane")
        }
    }

    /// P0 1193 follow-up (review finding 2): keys held for two creations, and a replayed key of the first opens a new
    /// creation (a held Cmd-D). The keys typed after it for the OTHER terminal stay that terminal's: each key goes to the
    /// terminal the focus named when it was typed. Before, every key after the replayed Cmd-D went to the new split.
    @Test func aReplayedCreationKeepsTheOtherTerminalsKeys() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            var refusals: [String] = []
            let previous = p.services.registry.refusalObserver
            p.services.registry.refusalObserver = { reason, quiet in refusals.append(reason); previous?(reason, quiet) }
            defer { p.services.registry.refusalObserver = previous }
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            // Two creations, neither with an early view: every key below waits, on any build.
            let firstCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            let secondCreation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.second.tab))
            var held = [try Self.press("d", [.command], keyCode: 2, in: p)] // for the first terminal
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            held += try Self.type("echo l2x\(nonce)x$((6*7))\r", in: p) // for the second terminal
            try #require(held.allSatisfy { $0 }, "the test needs every key held: \(held)")

            let before = Set(p.content.panes.keys)
            coordinator.resolve(firstCreation, landed: true, in: p.window)
            coordinator.resolve(secondCreation, landed: true, in: p.window)
            @MainActor func split() -> SurfaceID? {
                p.content.panes.filter { !before.contains($0.key) }.values.compactMap { pane in
                    pane.pane.tabs.first { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) }?.surface
                }.first
            }
            // First the held split's pane and the end of its hold, read from the app (no daemon request): a test's wait-for
            // runs on the app's own daemon connection, whose requests run in order, so a wait-for sent now would hold the
            // split's request back until it timed out (and the line waits for that split).
            try await PinnedPageTests.until({ split() != nil && !coordinator.isHolding(in: p.window) }, report: {
                "waited for the held Cmd-D's pane and the end of its hold; saw refusals \(refusals), \(Self.describe(p.content, p.window, p.services))"
            })
            let inSecond = try await Self.ran("l2x\(nonce)x42", on: p.second.surface, in: p)
            let made = split()
            let madeScreen = if let made { await Self.screen(made, in: p) } else { "" }
            let second = await Self.screen(p.second.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            // What the replayed Cmd-D did, for a failure report: the router's last action, refusals, the hold and the panes.
            let splitEnded = await Self.settles(p.content.pendingCreate, within: .seconds(1))
            let replay = "the held split's create work ended: \(splitEnded), "
                + "refusals \(refusals), holding \(coordinator.isHolding(in: p.window)), \(Self.describe(p.content, p.window, p.services)), "
                + "first terminal: \(first.suffix(200))"
            // The outcome the person sees first.
            #expect(!madeScreen.contains("l2x\(nonce)"), "the line typed for the second terminal ran in the new split: \(madeScreen.suffix(300))")
            #expect(inSecond, "the line typed for the second terminal did not run there: \(second.suffix(300)); \(replay)")
            #expect(made != nil, "the held Cmd-D made no pane; \(replay)")
        }
    }

    /// P0 1193 follow-up (coordinator 17:2xZ, from #29530's review): the hold ends at its bound while the focus names the
    /// terminal but its view is not in the window (a remount), so the window itself has the keyboard. The keys typed for
    /// the terminal go to it (its own encoder), never into whatever has the keyboard: before, the focused lane's keys ran
    /// again as typed (`NSApplication.sendEvent`) and were lost. A text field that takes the keyboard moves the focus
    /// model with it (the keys then already go to the terminal), so a remount is the way to make this state.
    @Test func heldKeysReachTheirTerminalWhenItsViewIsOffAtTheHoldsEnd() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            let creation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            let held = try Self.type("echo v1x\(nonce)x$((6*7))\r", in: p)
            try #require(held.allSatisfy { $0 }, "the test needs the keys held for the first creation: \(held)")

            // The first terminal's view leaves the window (a remount); the focus model still names it.
            guard case .terminal(let entry)? = p.first.pane.currentContent else {
                Issue.record("the first pane shows no terminal")
                return
            }
            let surface = entry.session.surfaceView
            let parent = try #require(surface.superview, "the terminal's view is not in a view")
            surface.removeFromSuperview()
            defer { parent.addSubview(surface) }
            let focused = p.content.focus.state.resolved == .terminal(pane: p.first.pane.paneKey, tab: p.first.tab)
            try #require(focused && !(p.window.firstResponder is TerminalSurfaceView),
                         "the test needs the focus on the first terminal while no terminal view has the keyboard; saw focus \(p.content.focus.state.resolved), first responder \(String(describing: p.window.firstResponder))")
            // The hold waits for a responder that takes the keys, then ends at its bound (300 ms after the reply).
            coordinator.resolve(creation, landed: true, in: p.window)
            let inFirst = try await Self.ran("v1x\(nonce)x42", on: p.first.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            #expect(inFirst, "the line typed for the first terminal did not run there (lost at the hold's end): \(first.suffix(300)); holding \(coordinator.isHolding(in: p.window)), end \(String(describing: coordinator.lastHoldEnd(in: p.window)))")
        }
    }

    /// P0 1193 follow-up (review of #29693 at bd1112a1cfa, defect 1): keys held for a terminal whose view is gone (its
    /// workspace hidden and its surface evicted) are typed by the daemon, in the order they were typed: "text, Return,
    /// Ctrl-C" never arrives as "text, Ctrl-C, Return". Before, a chord that is no app shortcut went out as its own daemon
    /// send, which can pass the send before it.
    @Test func heldKeysForAnEvictedTerminalKeepTheirOrder() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            try await Self.startByteReader(nonce: nonce, count: 4, on: p.first.surface, in: p)
            // The first creation has no early view: the keys typed for it wait for it, on any build.
            let creation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            var held = try Self.type("ab", in: p)
            held.append(try Self.press("\r", [], keyCode: 36, in: p))
            held.append(try Self.press("\u{3}", [.control], keyCode: 8, ignoring: "c", in: p))
            try #require(held.allSatisfy { $0 }, "the test needs the keys held for the first creation: \(held)")

            // Another workspace shows, and the first one hibernates (the product's own path: unmounted, its surfaces freed),
            // so the first terminal has no view and only the daemon can type the keys.
            let store = p.services.machines.local.store
            let firstWorkspace = try #require(store.workspace(containing: p.first.pane.pane.handle)?.id, "the first terminal's pane is in no workspace")
            #expect(p.services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ p.services.windows.active?.workspaceContent !== p.content },
                                            report: { "waited for another workspace in the window; it still shows the first one" })
            p.services.hibernateWorkspace(firstWorkspace)
            try await PinnedPageTests.until({ p.services.cache.existingTerminal(p.first.tab) == nil }, within: .seconds(5), report: {
                "waited for the first terminal's view to be evicted; it is still in the content cache"
            })
            coordinator.resolve(creation, landed: true, in: p.window)
            // The hold ends (app state) before any daemon read: a wait-for sent first on the app's connection would run
            // before the held keys' send-key and hold it back (the connection runs its requests in order).
            try await PinnedPageTests.until({ !coordinator.isHolding(in: p.window) }, within: .seconds(5), report: {
                "waited for the hold to end after the reply; saw end \(String(describing: coordinator.lastHoldEnd(in: p.window)))"
            })
            // The reader prints the hex of the 4 bytes it got: "ab", Return (0d), Ctrl-C (03), in that order. Read-screen
            // returns at once and runs after the sends before it, so poll it.
            let inOrder = try await Self.readerGot("K42x\(nonce)61620d03K", on: p.first.surface, in: p)
            let first = await Self.screen(p.first.surface, in: p)
            #expect(inOrder, "the keys held for the evicted terminal did not arrive as typed (61 62 0d 03): \(first.suffix(300))")
        }
    }

    /// P0 1193 (re-review of #29693 at bc84781571b, lead 00:2xZ): two typing runs held for one terminal whose view is gone
    /// (keys for another terminal typed between them) reach that terminal in the order they were typed. Each run is its
    /// own daemon send; before, a run of more than one request ("ab", then Return) could let the next run ("cd") in
    /// between its requests, so the shell got "ab", "cd", Return.
    @Test func twoHeldRunsForAnEvictedTerminalKeepTheirOrder() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            try await Self.startByteReader(nonce: nonce, count: 5, on: p.first.surface, in: p)
            // Two creations with no early view: every key below waits, on any build.
            let first = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            let second = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.second.tab))
            var held = try Self.type("ab", in: p)
            held.append(try Self.press("\r", [], keyCode: 36, in: p)) // run 1 for the first terminal: "ab", then Return
            try await Self.focus(p.second.pane, tab: p.second.tab, in: p)
            held += try Self.type("x", in: p) // for the second terminal, between the two runs
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            held += try Self.type("cd", in: p) // run 2 for the first terminal
            try #require(held.allSatisfy { $0 }, "the test needs every key held: \(held)")

            // Another workspace shows and the first one hibernates: both terminals lose their views, so the daemon types.
            let store = p.services.machines.local.store
            let firstWorkspace = try #require(store.workspace(containing: p.first.pane.pane.handle)?.id, "the first terminal's pane is in no workspace")
            #expect(p.services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ p.services.windows.active?.workspaceContent !== p.content },
                                            report: { "waited for another workspace in the window; it still shows the first one" })
            p.services.hibernateWorkspace(firstWorkspace)
            try await PinnedPageTests.until({ p.services.cache.existingTerminal(p.first.tab) == nil }, within: .seconds(5), report: {
                "waited for the first terminal's view to be evicted; it is still in the content cache"
            })
            coordinator.resolve(first, landed: true, in: p.window)
            coordinator.resolve(second, landed: true, in: p.window)
            try await PinnedPageTests.until({ !coordinator.isHolding(in: p.window) }, within: .seconds(5), report: {
                "waited for the hold to end after the replies; saw end \(String(describing: coordinator.lastHoldEnd(in: p.window)))"
            })
            // The reader prints the hex of the 5 bytes it got: a b Return c d, in that order.
            let inOrder = try await Self.readerGot("K42x\(nonce)61620d6364K", on: p.first.surface, in: p)
            let screen = await Self.screen(p.first.surface, in: p)
            #expect(inOrder, "the two runs held for the evicted terminal did not arrive as typed (61 62 0d 63 64): \(screen.suffix(300))")
        }
    }

    /// Every creation replied while the new terminal's view did not have the keyboard yet (the window was its first
    /// responder), so the reply's flush kept the hold. Then the terminal takes the keyboard: the line typed for it, and a
    /// line typed after it, run there at once, never after the hold's bound (perf extraction item 4: on the perf branch a
    /// hold kept every key for 2 s when no settle came after the terminal had the keyboard). The bound is set long, so a
    /// line that waits for it shows as missing, not as late.
    @Test func keysAfterTheReplyRunAtOnceWhenTheNewTerminalTakesTheKeyboard() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            coordinator.holdLimit = .seconds(60)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            let surfaceView = try #require(p.services.cache.existingTerminal(p.first.tab)?.session.surfaceView)
            p.window.makeFirstResponder(nil) // the new terminal's view does not have the keyboard yet
            let creation = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            let nonce = String(UInt32.random(in: 100_000...999_999))
            let heldBefore = try Self.type("echo r1x\(nonce)x$((6*7))\r", in: p)
            try #require(heldBefore.allSatisfy { $0 }, "the test needs the line typed before the reply held: \(heldBefore)")
            coordinator.resolve(creation, landed: true, in: p.window)
            try await Task.sleep(for: .milliseconds(300)) // the reply's flush ran; the terminal could not take the keys
            try #require(coordinator.isHolding(in: p.window), "the test needs the hold kept by the reply's flush: \(Self.describe(p.content, p.window, p.services))")

            // The terminal takes the keyboard, and the person types the next line.
            p.window.makeFirstResponder(surfaceView)
            _ = try Self.type("echo r2x\(nonce)x$((6*7))\r", in: p)

            // What the person sees: both lines ran in the new terminal, in order, long before the hold's bound.
            let first = try await Self.ranWithin("r1x\(nonce)x42", on: p.first.surface, seconds: 3, in: p)
            let second = try await Self.ranWithin("r2x\(nonce)x42", on: p.first.surface, seconds: 3, in: p)
            let screen = await Self.screen(p.first.surface, in: p)
            let other = await Self.screen(p.second.surface, in: p)
            #expect(first, "the line typed before the reply did not run in the new terminal within 3 s: \(screen.suffix(300))")
            #expect(second, "the line typed after the terminal took the keyboard did not run there within 3 s: \(screen.suffix(300))")
            if let a = screen.range(of: "r1x\(nonce)x42"), let b = screen.range(of: "r2x\(nonce)x42") {
                #expect(a.lowerBound < b.lowerBound, "the two lines ran out of order: \(screen.suffix(300))")
            }
            #expect(!other.contains("x\(nonce)x"), "a line typed for the new terminal ran in the other one: \(other.suffix(300))")
        }
    }

    /// The focus landed on a creation that has not replied yet, and the person typed a line for it, then pressed Cmd-W on
    /// it. The line never runs in the terminal that gets the focus after the close (perf extraction item 4: the close
    /// branch read only the focus expectation, so with the focus already landed it force-ran the held keys into whatever
    /// had the keyboard).
    @Test func cmdWOnACreationTheFocusLandedOnNeverRunsItsKeysInAnotherTerminal() async throws {
        try await Self.withTwoTerminals { p in
            let coordinator = Self.replayInTestWindow(p)
            coordinator.holdLimit = .seconds(60)
            try await Self.focus(p.first.pane, tab: p.first.tab, in: p)
            // The creation of the first terminal is still pending, and the focus already names its tab (no expectation).
            _ = try #require(coordinator.begin(in: p.window, generation: p.content.beginFocusIntent(), tab: p.first.tab))
            try #require(p.content.focus.state.expectation == nil && p.content.focus.state.resolved == .terminal(pane: p.first.pane.paneKey, tab: p.first.tab),
                         "the test needs the focus landed on the creation's tab: \(p.content.focus.state.resolved)")
            let nonce = String(UInt32.random(in: 100_000...999_999))
            _ = try Self.type("echo c1x\(nonce)x$((6*7))\r", in: p)
            _ = try Self.press("w", .command, keyCode: 13, in: p)

            // The close runs; the focus goes to the other terminal. What the person sees there: none of the line.
            try await PinnedPageTests.until({ !p.content.panes.values.contains { $0 === p.first.pane } || p.first.pane.pane.tabs.isEmpty },
                                            within: .seconds(20), report: { "Cmd-W did not close the first terminal: \(Self.describe(p.content, p.window, p.services))" })
            try await Task.sleep(for: .seconds(1)) // a held line run into the other terminal would show by now
            let other = await Self.screen(p.second.surface, in: p)
            #expect(!other.contains("c1x\(nonce)"), "the line typed for the closed terminal ran in the other one: \(other.suffix(300))")
        }
    }

    /// Whether `marker` shows on `surface` within `seconds` (polls read-screen; a narrow pane wraps lines).
    private static func ranWithin(_ marker: String, on surface: SurfaceID, seconds: Double, in p: Panes) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        repeat {
            if await screen(surface, in: p).replacingOccurrences(of: "\n", with: "").contains(marker) { return true }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return false
    }
}
