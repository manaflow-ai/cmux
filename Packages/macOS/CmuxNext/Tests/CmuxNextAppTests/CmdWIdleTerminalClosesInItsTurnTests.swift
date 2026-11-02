import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import Foundation
import Testing

/// SHORTCUT LATENCY SL-3 (SHORTCUT FRAMES F6, 2026-11-02): Cmd-W on a live terminal showed its first changed frame
/// 4 to 6 display refreshes after the key (120 Hz, real HID): the close asked the daemon what the terminal runs after
/// the key (`TabCloseGuard`, the close warning), and the tab left only when that read answered, on a later turn.
/// Now the tab leaves the strip in the key's own turn while its terminal stays alive; the daemon's read then decides:
/// nothing runs, the close goes to the daemon; a program runs, the tab comes back in place and the question shows.
/// A program is never ended without the question (lead, #31875: a resumed editor closed with no question is data loss),
/// whatever the shell reported before the key: the harness's /bin/sh sends no OSC 133 C, as a program started from a
/// line-editor key binding (`fg`, `$EDITOR`) does not.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWIdleTerminalClosesInItsTurnTests {
    @Test func cmdWOnAnIdleTerminalLeavesInTheKeysTurnAndClosesAfterTheRead() async throws {
        try await Self.withFocusedTerminal { t in
            let performed = t.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            #expect(performed)
            #expect(!t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "the tab did not leave the strip in the key's turn")
            // The read finds the shell only: the close goes to the daemon, and the tab never comes back.
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(t.tab.id) && t.store.closingTabIDs.isEmpty },
                                            report: { "waiting for the close: asking \(TabCloseGuard.asking), closing \(t.store.closingTabIDs)" })
            #expect(!t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "an idle terminal's tab came back after its close")
            #expect(Self.question() == nil, "an idle terminal's close asked")
        }
    }

    /// (a) A stopped program resumed with `fg` from a key binding sends no OSC 133 C: the shell's prompt report still
    /// stands, and anything read at that prompt says "no program". Cmd-W must still ask, and the program must live.
    @Test func cmdWAfterFgFromAKeyBindingAsks() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("sleep 600\r", t)
            try await Self.waitRunning("sleep", t)
            try await Self.input("\u{1A}", t) // Ctrl-Z: stopped, the shell is back in front
            try await Self.waitRunning(nil, t)
            try await Self.input("printf '\\033]133;A\\007'\r", t) // the prompt's report, as an integrated shell sends it
            try await PinnedPageTests.until({ t.tab.promptSinceMs != nil }, report: { "no prompt reached the store" })
            try await Self.settle()
            try await Self.input("fg\r", t) // resumed with no OSC 133 C
            try await Self.waitRunning("sleep", t)
            try await Self.cmdWAsks(t)
        }
    }

    /// (b) A command started just before Cmd-W: its OSC 133 C has not reached the store (here it sends none), so the
    /// prompt's report still stands. Cmd-W must still ask, and the program must live.
    @Test func cmdWRightAfterACommandStartedAsks() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("printf '\\033]133;A\\007'\r", t)
            try await PinnedPageTests.until({ t.tab.promptSinceMs != nil }, report: { "no prompt reached the store" })
            try await Self.settle()
            try await Self.input("sleep 600\r", t)
            try await Self.waitRunning("sleep", t)
            try await Self.cmdWAsks(t)
        }
    }

    /// (H1, review of #31875) While the daemon's read decides, the tab is only hidden: its terminal view is not freed,
    /// so the Cancel of the question brings back the SAME view (its scrollback, its state), not a view made again.
    @Test func aCancelledCloseBringsBackTheSameTerminalView() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("sleep 600\r", t)
            try await Self.waitRunning("sleep", t)
            // The selected tab's view is made when the pane shows it (a later turn): wait for it, not for the clock.
            try await PinnedPageTests.until({ t.services.cache.existingTerminal(t.tab.id) != nil }, report: { "no terminal view before the close" })
            let view = try #require(t.services.cache.existingTerminal(t.tab.id))
            let viewID = ObjectIdentifier(view)
            // The read is held: the tab stays hidden long enough for every gone-tab watcher to wake for the hide.
            let hold = t.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(t.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            #expect(!t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "the tab did not leave in the key's turn")
            try await Self.turns()
            #expect(t.services.cache.existingTerminal(t.tab.id).map(ObjectIdentifier.init) == viewID,
                    "the hidden tab's terminal view was freed during the read")
            hold.release()
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(t.tab.id) }, report: { "the cancelled close still asks" })
            #expect(t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "Cancel did not bring the tab back")
            #expect(t.services.cache.existingTerminal(t.tab.id).map(ObjectIdentifier.init) == viewID,
                    "Cancel brought back a new terminal view, not the same one")
            try await Self.waitRunning("sleep", t)
        }
    }

    /// (H1, browser tabs) A close of several tabs that includes a running terminal hides them all while the read decides;
    /// Cancel brings back each browser tab's SAME page (never released, so never reloaded: its form input and scroll stay).
    @Test func aCancelledCloseOfSeveralTabsKeepsTheBrowserPage() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("sleep 600\r", t)
            try await Self.waitRunning("sleep", t)
            let browser = try await t.connection.newFrontendBrowserTab(url: "data:text/html,<input id=f value=typed>", engine: .webkit,
                                                                       in: t.pane.pane.handle, activate: false)
            try await PinnedPageTests.until({ t.store.tab(surface: browser.surface).map { t.pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let page = try #require(t.store.tab(surface: browser.surface))
            t.pane.select(TabID(page.id))
            try await PinnedPageTests.until({ t.services.cache.existingBrowser(page.id) != nil }, report: { "the browser page never loaded" })
            let pageEntry = try #require(t.services.cache.existingBrowser(page.id))
            t.pane.select(TabID(t.tab.id))
            let neighbour = try #require(t.pane.orderedIDs.first { $0.rawValue != t.tab.id && $0.rawValue != page.id })
            let hold = t.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            // Close Other Tabs from the neighbour: the running terminal and the page close together.
            #expect(t.services.registry.perform("closeOtherTabsInPane", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: neighbour.rawValue), origin: .user)))
            #expect(!t.pane.orderedIDs.map(\.rawValue).contains(page.id), "the page did not leave in the key's turn")
            try await Self.turns()
            #expect(t.services.cache.existingBrowser(page.id) === pageEntry, "the hidden page was released during the read")
            hold.release()
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(t.tab.id) }, report: { "the cancelled close still asks" })
            #expect(t.pane.orderedIDs.map(\.rawValue).contains(page.id), "Cancel did not bring the page back")
            #expect(t.services.cache.existingBrowser(page.id) === pageEntry, "Cancel brought back a new page (it reloaded)")
        }
    }

    /// (H2, review of #31875) Keys typed while the daemon's read decides belong to the close's answer: they never run in
    /// the neighbour the hide shows, and with a program running they come back to the terminal that stays, in order,
    /// after Cancel. A Return typed during the read never presses the question's Close.
    @Test func keysTypedDuringTheReadWaitForTheAnswerAndNeverPressClose() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("cat\r", t)
            try await Self.waitRunning("cat", t)
            // A terminal neighbour that the hide shows (the pane's first tab may be an agent chat).
            let other = try await t.connection.newTab(in: t.pane.pane.handle).surface
            try await PinnedPageTests.until({ t.store.tab(surface: other).map { t.pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let neighbour = try #require(t.store.tab(surface: other))
            t.pane.select(TabID(t.tab.id))
            try await PinnedPageTests.until({ t.pane.stripModel.selectedID?.rawValue == t.tab.id })
            let hold = t.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            let window = try #require(t.pane.view.window)
            try Self.press("w", .command, keyCode: 13, in: window, t)
            #expect(TabCloseGuard.reading.contains(t.tab.id), "Cmd-W did not wait for the read")
            try await Self.turns() // the focus has moved to the neighbour the hide shows
            let nonce = String(UInt32.random(in: 100_000...999_999))
            for character in "kq\(nonce)\r" { try Self.press(String(character), keyCode: character == "\r" ? 36 : 0, in: window, t) }
            try await Self.turns()
            let neighbourScreen = (try? await t.connection.request(ReadScreenRequest(surface: neighbour.surface), timeout: .seconds(5)))?.text ?? ""
            #expect(!neighbourScreen.contains("kq\(nonce)"), "keys typed during the read ran in the neighbour: \(neighbourScreen.suffix(300))")

            hold.release()
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            try await Self.turns()
            #expect(Self.question() != nil, "a Return typed during the read pressed the question's Close")
            // The keys wait for the answer: while the question shows, the terminal it asks about has not got them.
            let asking = (try? await t.connection.request(ReadScreenRequest(surface: t.tab.surface), timeout: .seconds(5)))?.text ?? ""
            #expect(!asking.contains("kq\(nonce)"), "keys typed during the read ran in the closing terminal before the answer: \(asking.suffix(300))")
            #expect(t.store.tab(surface: t.tab.surface) != nil, "the terminal running cat closed with no answer")
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            // cat writes the line back after the terminal's own echo: the whole line, in order, in the terminal that stays.
            let back = try? await t.connection.request(WaitForTextRequest(surface: t.tab.surface, pattern: "kq\(nonce)", timeoutMs: 10_000),
                                                       timeout: .seconds(15))
            #expect(back?.matched == true, "the keys typed during the read did not come back to the terminal that stays")
            try await Self.waitRunning("cat", t)
        }
    }

    /// (Review of #31875, #29409 again) A second Cmd-W during the read (a double press, a key repeat) closes the
    /// neighbour the hide shows at once, and the keys held for the first close keep waiting: they never run in that
    /// neighbour, and after Cancel the line comes back whole to the terminal that stays.
    @Test func aSecondCmdWDuringTheReadKeepsTheHeldKeysForTheAnswer() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("cat\r", t)
            try await Self.waitRunning("cat", t)
            var neighbours: [TabModel] = []
            for _ in 0..<2 {
                let surface = try await t.connection.newTab(in: t.pane.pane.handle).surface
                try await PinnedPageTests.until({ t.store.tab(surface: surface).map { t.pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
                neighbours.append(try #require(t.store.tab(surface: surface)))
            }
            t.pane.select(TabID(t.tab.id))
            try await PinnedPageTests.until({ t.pane.stripModel.selectedID?.rawValue == t.tab.id })
            let hold = t.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            let window = try #require(t.pane.view.window)
            let nonce = String(UInt32.random(in: 100_000...999_999))
            try Self.press("w", .command, keyCode: 13, in: window, t)
            try await Self.turns()
            for character in "dw\(nonce)" { try Self.press(String(character), in: window, t) }
            try Self.press("w", .command, keyCode: 13, in: window, t) // the second, quick Cmd-W
            for character in "x\r" { try Self.press(String(character), keyCode: character == "\r" ? 36 : 0, in: window, t) }
            try await Self.turns()
            for neighbour in neighbours {
                let screen = (try? await t.connection.request(ReadScreenRequest(surface: neighbour.surface), timeout: .seconds(5)))?.text ?? ""
                #expect(!screen.contains("dw\(nonce)"), "keys held for the first close ran in a neighbour: \(screen.suffix(300))")
            }
            hold.release()
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            let back = try? await t.connection.request(WaitForTextRequest(surface: t.tab.surface, pattern: "dw\(nonce)", timeoutMs: 10_000),
                                                       timeout: .seconds(15))
            #expect(back?.matched == true, "the keys held for the first close did not come back to the terminal that stays")
        }
    }

    /// (Review of #31875, Low) The close button of another terminal, one that does not have the focus, pressed while a
    /// hidden close reads: that close never takes the keys typed meanwhile. They go to the terminal that has the focus
    /// (the neighbour the hide showed), never into the other terminal when its program asks and the person cancels.
    @Test func aCloseOfAnUnfocusedTerminalDuringTheReadNeverTakesTheHeldKeys() async throws {
        try await Self.withFocusedTerminal { t in
            let neighbour = try await Self.newTerminal(t)
            let running = try await Self.newTerminal(t) // runs cat: its close asks
            _ = try await t.connection.request(SendInputRequest(surface: running.surface, text: "cat\r"))
            try await Self.waitRunning("cat", t, surface: running.surface)
            t.pane.select(TabID(t.tab.id))
            let window = try #require(t.pane.view.window)
            let focused = { t.services.keyRouter.focus(for: window).0?.focus.state.terminalTab }
            try await PinnedPageTests.until({ focused() == t.tab.id }, report: { "the closing terminal never had the focus: \(focused() ?? "none")" })
            let hold = t.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            try Self.press("w", .command, keyCode: 13, in: window, t) // the idle terminal's Cmd-W: hidden, it reads
            try await PinnedPageTests.until({ focused() == neighbour.id && hold.held == 1 },
                                            report: { "focus \(focused() ?? "none"), neighbour \(neighbour.id), reads held \(hold.held)" })
            let nonce = String(UInt32.random(in: 100_000...999_999)), before = "kq\(nonce)", after = "zz\(nonce)"
            for character in before { try Self.press(String(character), in: window, t) }
            t.pane.handle(.close(TabID(running.id), source: .mouse)) // its close button: the running terminal hides and reads
            try await PinnedPageTests.until({ hold.held == 2 }, report: { "the running terminal's close did not read: \(hold.held) held" })
            for character in after { try Self.press(String(character), in: window, t) }
            hold.release()
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no question for the running terminal" })
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            let typed = try? await t.connection.request(WaitForTextRequest(surface: neighbour.surface, pattern: before + after, timeoutMs: 10_000),
                                                        timeout: .seconds(15))
            let screen = (try? await t.connection.request(ReadScreenRequest(surface: running.surface), timeout: .seconds(5)))?.text ?? ""
            #expect(typed?.matched == true, "the keys typed during the read did not reach the focused terminal: \(typed?.text.suffix(300) ?? "no answer")")
            #expect(!screen.contains(before) && !screen.contains(after), "the cancelled close's terminal got the focused one's keys: \(screen.suffix(300))")
            #expect(t.store.tab(surface: running.surface) != nil, "the terminal running cat closed with no answer")
        }
    }

    /// (Review of #32291, the reads in the other order) The running terminal's question shows before the idle terminal's
    /// read ends: that close ends while the question asks, and Cancel still types only the question's own keys into the
    /// terminal it asked about. The keys typed for the focused neighbour go to it.
    @Test func aCloseThatEndsWhileAnotherTerminalAsksKeepsItsKeysForTheFocusedTerminal() async throws {
        try await Self.withFocusedTerminal { t in
            let neighbour = try await Self.newTerminal(t)
            let running = try await Self.newTerminal(t) // runs cat: its close asks
            _ = try await t.connection.request(SendInputRequest(surface: running.surface, text: "cat\r"))
            try await Self.waitRunning("cat", t, surface: running.surface)
            t.pane.select(TabID(t.tab.id))
            let window = try #require(t.pane.view.window)
            let focused = { t.services.keyRouter.focus(for: window).0?.focus.state.terminalTab }
            try await PinnedPageTests.until({ focused() == t.tab.id }, report: { "the closing terminal never had the focus: \(focused() ?? "none")" })
            let hold = t.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            try Self.press("w", .command, keyCode: 13, in: window, t) // the idle terminal's Cmd-W: hidden, it reads
            try await PinnedPageTests.until({ focused() == neighbour.id && hold.held == 1 },
                                            report: { "focus \(focused() ?? "none"), neighbour \(neighbour.id), reads held \(hold.held)" })
            let nonce = String(UInt32.random(in: 100_000...999_999)), typed = "rv\(nonce)"
            for character in typed { try Self.press(String(character), in: window, t) }
            t.pane.handle(.close(TabID(running.id), source: .mouse)) // its close button: the running terminal hides and reads
            try await PinnedPageTests.until({ hold.held == 2 }, report: { "the running terminal's close did not read: \(hold.held) held" })
            hold.releaseNewest() // the running terminal answers first: its question shows while the idle one still reads
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no question for the running terminal" })
            hold.release() // the idle terminal's close ends while the question asks
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(t.tab.id) }, report: { "the idle close never ended: asking \(TabCloseGuard.asking)" })
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            let back = try? await t.connection.request(WaitForTextRequest(surface: neighbour.surface, pattern: typed, timeoutMs: 10_000), timeout: .seconds(15))
            let screen = (try? await t.connection.request(ReadScreenRequest(surface: running.surface), timeout: .seconds(5)))?.text ?? ""
            #expect(back?.matched == true, "the keys typed for the focused terminal did not reach it: \(back?.text.suffix(300) ?? "no answer")")
            #expect(!screen.contains(typed), "Cancel typed another close's keys into the terminal it asked about: \(screen.suffix(300))")
        }
    }

    /// (Review of #32291, key order) Cmd-W on an idle terminal, keys, a quick second Cmd-W on the neighbour that runs a
    /// program, more keys. The neighbour's question shows before the first close's read ends; that close ends while the
    /// question asks. After Cancel, the neighbour gets every key in typing order (before: the second close's keys came
    /// first, so a typed "ab" arrived "ba").
    @Test func keysHeldForTwoClosesArriveInTypingOrder() async throws {
        try await Self.withFocusedTerminal { t in
            let running = try await Self.newTerminal(t) // the neighbour the first hide shows; runs cat, so its close asks
            _ = try await Self.newTerminal(t) // the neighbour the second hide shows
            _ = try await t.connection.request(SendInputRequest(surface: running.surface, text: "cat\r"))
            try await Self.waitRunning("cat", t, surface: running.surface)
            t.pane.select(TabID(t.tab.id))
            let window = try #require(t.pane.view.window)
            let focused = { t.services.keyRouter.focus(for: window).0?.focus.state.terminalTab }
            try await PinnedPageTests.until({ focused() == t.tab.id }, report: { "the idle terminal never had the focus: \(focused() ?? "none")" })
            let hold = t.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            let nonce = String(UInt32.random(in: 100_000...999_999)), first = "o1\(nonce)", second = "o2\(nonce)"
            try Self.press("w", .command, keyCode: 13, in: window, t) // the idle terminal: hidden, it reads
            try await PinnedPageTests.until({ focused() == running.id && hold.held == 1 }, report: { "focus \(focused() ?? "none"), reads held \(hold.held)" })
            for character in first { try Self.press(String(character), in: window, t) }
            try Self.press("w", .command, keyCode: 13, in: window, t) // the quick second Cmd-W: the running neighbour hides and reads
            try await PinnedPageTests.until({ hold.held == 2 }, report: { "the second Cmd-W did not read: \(hold.held) held" })
            for character in second { try Self.press(String(character), in: window, t) }
            hold.releaseNewest() // the running neighbour answers first: its question shows while the idle close still reads
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no question for the running neighbour" })
            hold.release() // the idle close ends while the question asks
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(t.tab.id) }, report: { "the idle close never ended: asking \(TabCloseGuard.asking)" })
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            // cat writes each line back after the terminal's echo; wait for one of the two orders, then read the screen.
            _ = try? await t.connection.request(WaitForTextRequest(surface: running.surface, pattern: "o\\d\(nonce)o\\d\(nonce)", timeoutMs: 10_000), timeout: .seconds(15))
            let screen = (try? await t.connection.request(ReadScreenRequest(surface: running.surface), timeout: .seconds(5)))?.text ?? ""
            #expect(screen.contains(first + second) && !screen.contains(second + first),
                    "the held keys did not reach the terminal that stays in typing order (\(first)\(second)): \(screen.suffix(300))")
        }
    }

    /// (Review of #32291) While the question shows, the held keys wait for its answer, but a key typed at the question is
    /// the question's: Escape through the app's key path cancels it, and the line held during the read comes back whole
    /// to the terminal that stays.
    @Test func escapeAtTheQuestionCancelsItAndTheHeldLineComesBack() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("cat\r", t)
            try await Self.waitRunning("cat", t)
            _ = try await Self.newTerminal(t) // the neighbour the hide shows
            t.pane.select(TabID(t.tab.id))
            try await PinnedPageTests.until({ t.pane.stripModel.selectedID?.rawValue == t.tab.id })
            let hold = t.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            let window = try #require(t.pane.view.window)
            try Self.press("w", .command, keyCode: 13, in: window, t)
            try await PinnedPageTests.until({ hold.held == 1 }, report: { "the close did not read" })
            let nonce = String(UInt32.random(in: 100_000...999_999))
            for character in "es\(nonce)" { try Self.press(String(character), in: window, t) }
            hold.release()
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            try Self.press("\u{1B}", keyCode: 53, in: window, t)
            try await PinnedPageTests.until({ Self.question() == nil && !TabCloseGuard.asking.contains(t.tab.id) },
                                            report: { "Escape did not answer the question: asking \(TabCloseGuard.asking)" })
            #expect(t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "Escape closed the terminal running cat")
            let back = try? await t.connection.request(WaitForTextRequest(surface: t.tab.surface, pattern: "es\(nonce)", timeoutMs: 10_000),
                                                       timeout: .seconds(15))
            #expect(back?.matched == true, "the line held during the read did not come back to the terminal that stays")
        }
    }

    // MARK: Fixture

    /// A new terminal tab at the end of `t`'s pane, once its strip lists it.
    private static func newTerminal(_ t: Terminal) async throws -> TabModel {
        let surface = try await t.connection.newTab(in: t.pane.pane.handle).surface
        try await PinnedPageTests.until({ t.store.tab(surface: surface).map { t.pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
        return try #require(t.store.tab(surface: surface))
    }

    private struct Terminal {
        let services: AppServices
        let connection: DaemonConnection
        let store: DaemonStore
        let pane: PaneController
        let tab: TabModel
    }

    /// A focused live terminal in a pane that keeps another tab, its shell started.
    private static func withFocusedTerminal(_ body: (Terminal) async throws -> Void) async throws {
        try await PinnedPageTests.withApp(heldKeyReplay: { event, window, router in
            if !router.interceptKeyDown(event, in: window) { window.sendEvent(event) }
        }) { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
            let surface = try await connection.newTab(in: paneModel.handle).surface
            try await PinnedPageTests.until({ store.tab(surface: surface) != nil })
            let tab = try #require(store.tab(surface: surface))
            let pane = try #require(services.paneController(for: paneModel))
            try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue).contains(tab.id) && pane.orderedIDs.count > 1 })
            pane.select(TabID(tab.id))
            try #require(services.windows.active?.focusedPane === pane, "the terminal's pane is not the focused one")
            try #require(TabCloseGuard.asks([tab], services: services), "the terminal close warning does not apply")
            let terminal = Terminal(services: services, connection: connection, store: store, pane: pane, tab: tab)
            try await Self.waitRunning(nil, terminal)
            defer { if let record = Self.question() { _ = CmuxDialogCenter.shared.press(record.id, button: "cancel") } }
            try await body(terminal)
        }
    }

    /// A key-down through the app's key path (the key router, then the window), as the person types it.
    private static func press(_ characters: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0, in window: NSWindow, _ t: Terminal) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        if !t.services.keyRouter.interceptKeyDown(event, in: window) { window.sendEvent(event) }
    }

    /// A few main-actor turns: the focus, watchers and flushes a change starts have run (a test harness bound).
    private static func turns() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private static func input(_ text: String, _ t: Terminal) async throws {
        _ = try await t.connection.request(SendInputRequest(surface: t.tab.surface, text: text))
    }

    /// Waits until the daemon names `program` as the foreground program of the terminal (`surface`, else `t`'s; nil: its shell only).
    private static func waitRunning(_ program: String?, _ t: Terminal, surface: SurfaceID? = nil) async throws {
        var last = "no answer"
        for _ in 0..<100 {
            // Only an answer counts: a read that did not answer is not "its shell only".
            if let answer = await t.connection.readProcessInfo(surface ?? t.tab.surface, timeout: .seconds(1)) {
                if answer.runningProgram == program { return }
                last = answer.runningProgram ?? "its shell only"
            }
            try await Task.sleep(for: .milliseconds(100)) // test harness polling the daemon
        }
        Issue.record("the terminal never ran \(program ?? "its shell only") in front (last: \(last))")
    }

    /// Room for anything the app reads at the prompt before the key (a test harness bound, not product timing).
    private static func settle() async throws { try await Task.sleep(for: .milliseconds(1_500)) }

    private static func question() -> CmuxDialogCenter.Record? {
        CmuxDialogCenter.shared.records.first { $0.spec.identifier == "cmux.dialog.confirmation" }
    }

    /// Cmd-W on the running program: the question shows, the tab is back in its strip, and the program still runs;
    /// Cancel keeps it.
    private static func cmdWAsks(_ t: Terminal) async throws {
        let performed = t.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
        #expect(performed)
        try await PinnedPageTests.until({ Self.question() != nil }, report: {
            "no close question: asking \(TabCloseGuard.asking), in strip \(t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id)), closing \(t.store.closingTabIDs)"
        })
        #expect(t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "the tab is not back in its strip while its question shows")
        try await Self.waitRunning("sleep", t)
        _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
        try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(t.tab.id) }, report: { "the cancelled close still asks" })
        #expect(t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "Cancel did not keep the tab")
        try await Self.waitRunning("sleep", t)
    }
}
