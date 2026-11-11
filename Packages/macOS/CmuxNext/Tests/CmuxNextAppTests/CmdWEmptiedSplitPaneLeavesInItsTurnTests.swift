import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextTabs
import Foundation
import Testing

/// Leo, 2026-10-25: "closing the right pane seems be like... waiting for the right tab's closing animation to play
/// before closing"; 2026-11-03: "it's so slow to open and close ... it's nigh instant for claude and codex". Cmd-W on
/// the last terminal of a split's pane kept the pane on screen until the daemon's process read answered (up to 1 s
/// under load, `TabCloseGuard`): the in-turn hide (#31875) covered only a pane that keeps another tab. Now the pane
/// leaves its window in the key's own turn while its terminal stays alive; a running program brings it back, with its
/// focus, before the question.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWEmptiedSplitPaneLeavesInItsTurnTests {
    @Test func cmdWOnASplitsLastIdleTerminalHidesThePaneInTheKeysTurn() async throws {
        try await Self.withFocusedSplit { s in
            let hold = s.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(s.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            #expect(!Self.shown(s), "the emptied pane stayed on screen while the daemon's read decided")
            #expect(s.services.windows.active?.focusedPane !== s.pane, "the focus stayed on the pane that left")
            try await Self.turns()
            #expect(!Self.shown(s), "the emptied pane came back during the read")
            hold.release()
            try await PinnedPageTests.until({ !Self.inDaemon(s) }, report: { "the pane's close never landed" })
            try await Self.turns()
            #expect(!Self.shown(s), "the closed pane came back after its close landed")
            #expect(Self.question() == nil, "an idle terminal's close asked")
        }
    }

    @Test func aRunningProgramBringsThePaneBackWithItsFocusBeforeTheQuestion() async throws {
        try await Self.withFocusedSplit { s in
            _ = try await s.connection.request(SendInputRequest(surface: s.tab.surface, text: "sleep 600\r"))
            try await Self.waitRunning("sleep", s)
            let hold = s.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(s.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            #expect(!Self.shown(s), "the emptied pane stayed on screen while the daemon's read decided")
            hold.release()
            try await Self.measureTakeBack(s)
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            #expect(Self.shown(s), "the pane is not back on screen while its question shows")
            #expect(Self.live(s)?.orderedIDs.map(\.rawValue).contains(s.tab.id) == true, "the tab is not back in its strip while its question shows")
            try await Self.paneIsBackAndCancelKeepsIt(s)
        }
    }

    /// The daemon's read answers after the closed pane's views left the window: a slow read that outlasts the close's
    /// spring, and every close that does not spring (Reduce Motion, pane animations off, a close that moves no pane).
    /// The layout view tears the hidden pane down when its close lands (`LayoutViewContext.releaseRetired`), so the
    /// take-back shows the pane again from nothing. The running program still brings its pane back, with its focus,
    /// before the question, and Cancel keeps it.
    @Test func aProgramFoundAfterTheClosedPanesViewsLeftBringsThePaneBackWithItsFocus() async throws {
        try await Self.withFocusedSplit { s in
            _ = try await s.connection.request(SendInputRequest(surface: s.tab.surface, text: "sleep 600\r"))
            try await Self.waitRunning("sleep", s)
            let hold = s.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(s.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            #expect(!Self.shown(s), "the emptied pane stayed on screen while the daemon's read decided")
            // The read answers only now: the close landed (or showed with no spring) and took the pane's views away.
            try await PinnedPageTests.until({ s.pane.view.window == nil }, report: { "the closed pane's views never left the window during the read" })
            hold.release()
            try await Self.measureTakeBack(s)
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            #expect(Self.shown(s), "the pane is not back on screen while its question shows")
            try await Self.paneIsBackAndCancelKeepsIt(s)
        }
    }

    /// (Review of #32898) Two quick Cmd-Ws on a split of two terminals, the first running a program: the second empties
    /// the pane, which hides. Whichever read answers first, the first terminal's question shows its pane again with it,
    /// and the idle terminal's close goes through.
    @Test func aProgramsTabBackShowsThePaneALaterCloseHid() async throws {
        try await Self.withFocusedSplit { s in
            let other = try await s.connection.newTab(in: s.handle).surface
            try await PinnedPageTests.until({ s.store.tab(surface: other).map { s.pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let idle = try #require(s.store.tab(surface: other))
            _ = try await s.connection.request(SendInputRequest(surface: s.tab.surface, text: "sleep 600\r"))
            try await Self.waitRunning("sleep", s)
            s.pane.select(TabID(s.tab.id))
            try await PinnedPageTests.until({ s.pane.stripModel.selectedID?.rawValue == s.tab.id })
            let hold = s.services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            #expect(s.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            #expect(Self.shown(s), "a close that keeps a tab in its pane hid the pane")
            #expect(s.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            #expect(!Self.shown(s), "the close of the pane's last other tab did not hide the pane")
            hold.release()
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            try await PinnedPageTests.until({ Self.shown(s) && Self.live(s)?.orderedIDs.map(\.rawValue).contains(s.tab.id) == true },
                                            report: { "the pane did not come back with the program's tab: shown \(Self.shown(s)), strip \(Self.live(s)?.orderedIDs ?? [])" })
            try await PinnedPageTests.until({ s.store.tab(surface: idle.surface) == nil }, report: { "the idle terminal's close never landed" })
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(s.tab.id) }, report: { "the cancelled close still asks" })
            try await Self.turns()
            #expect(Self.shown(s), "Cancel did not keep the pane")
            #expect(Self.inDaemon(s), "Cancel did not keep the pane in the daemon's tree")
        }
    }

    /// Cmd-W -> the emptied pane gone from the shown layout, per round: in the key's turn with the hide, a daemon read
    /// later without it. Prints its p50/p95 (same harness before and after, the PR's Performance table).
    @Test func measureCmdWToEmptiedPaneGone() async throws {
        var samples: [Double] = []
        try await PinnedPageTests.withApp { services, connection in
            for _ in 0..<15 {
                let s = try await Self.split(services, connection)
                let start = ContinuousClock.now
                #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
                while Self.shown(s), ContinuousClock.now - start < .seconds(5) { try await Task.sleep(for: .microseconds(250)) } // harness timing loop
                let elapsed = ContinuousClock.now - start
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
                try await PinnedPageTests.until({ !Self.inDaemon(s) }, report: { "the pane's close never landed" })
            }
        }
        let sorted = samples.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        print("CLOSE-EMPTIED-PANE-BENCH n=\(sorted.count) p50_ms=\(String(format: "%.2f", pct(0.5))) p95_ms=\(String(format: "%.2f", pct(0.95))) max_ms=\(String(format: "%.2f", sorted.last ?? 0))")
        #expect(sorted.count == 15)
    }

    // MARK: Fixture

    private struct Split {
        let services: AppServices
        let connection: DaemonConnection
        let store: DaemonStore
        /// The pane object before a close: after one, read ``live(_:)``.
        let pane: PaneController
        let workspace: WorkspaceContentController
        /// The pane's key in its window (`PaneController.paneKey`).
        let key: String
        let handle: CmuxNextDaemon.PaneID
        let tab: TabModel
    }

    /// A right split of the first pane: one live terminal, its pane focused, its shell at its prompt.
    private static func split(_ services: AppServices, _ connection: DaemonConnection) async throws -> Split {
        let store = services.daemon.store
        let first = try #require(store.workspaces.first?.screens.first?.panes.first)
        let surface = try await connection.split(first.handle, direction: .right).surface
        func paneModel() -> PaneModel? { store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).first { $0.tabs.contains { $0.surface == surface } } }
        try await PinnedPageTests.until({ paneModel().flatMap(services.paneController(for:)).map { $0.orderedIDs.count == 1 } == true },
                                        report: { "the split's pane never showed its terminal" })
        let model = try #require(paneModel())
        let pane = try #require(services.paneController(for: model))
        let tab = try #require(store.tab(surface: surface))
        let workspace = try #require(pane.workspace)
        PaneHandlers.focus(pane.layoutPaneID, in: workspace)
        try await PinnedPageTests.until({ services.windows.active?.focusedPane === pane }, report: { "the split's pane never took the focus" })
        try #require(TabCloseGuard.asks([tab], services: services), "the terminal close warning does not apply")
        let s = Split(services: services, connection: connection, store: store, pane: pane, workspace: workspace, key: pane.paneKey, handle: model.handle, tab: tab)
        try await waitRunning(nil, s)
        try #require(shown(s), "the split's pane is not on screen")
        return s
    }

    private static func withFocusedSplit(_ body: (Split) async throws -> Void) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let s = try await split(services, connection)
            defer { if let record = question() { _ = CmuxDialogCenter.shared.press(record.id, button: "cancel") } }
            try await body(s)
        }
    }

    /// The question shows: the pane has the focus and its terminal again; Cancel keeps the pane, its terminal, the
    /// keyboard in it and the program.
    private static func paneIsBackAndCancelKeepsIt(_ s: Split) async throws {
        try await PinnedPageTests.until({ focusIsBack(s) }, report: { "the focus did not come back to the pane the question asks about: \(focusReport(s))" })
        try await PinnedPageTests.until({ terminalShows(s) }, report: { "the pane came back without its terminal: \(focusReport(s))" })
        _ = CmuxDialogCenter.shared.press(try #require(question()).id, button: "cancel")
        try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(s.tab.id) }, report: { "the cancelled close still asks" })
        try await turns()
        #expect(shown(s), "Cancel did not keep the pane")
        #expect(inDaemon(s), "Cancel did not keep the pane in the daemon's tree")
        #expect(focusIsBack(s) && terminalShows(s), "Cancel did not keep the pane's focus and terminal: \(focusReport(s))")
        try await PinnedPageTests.until({ keyboardIsInPane(s) }, report: { "the keyboard is not in the pane after Cancel: \(focusReport(s))" })
        try await waitRunning("sleep", s)
    }

    /// The pane object the window holds for the split's pane now. A close taken back before its views left shows the
    /// object from before Cmd-W again; after they left (the close landed, or it did not spring) the window makes a new
    /// one for the same pane. What the person has is the same, so the tests read this one, never `s.pane` after a close.
    private static func live(_ s: Split) -> PaneController? { s.workspace.paneController(key: s.key) }

    /// The focus is back on the split's pane, as the person has it: the window's focused pane is the split's pane, in
    /// the window, with the program's tab in its strip, selected.
    private static func focusIsBack(_ s: Split) -> Bool {
        guard let pane = live(s), s.services.windows.active?.focusedPane === pane, pane.view.window != nil else { return false }
        return pane.orderedIDs.map(\.rawValue).contains(s.tab.id) && pane.stripModel.selectedID?.rawValue == s.tab.id
    }

    /// The terminal's own view is in the split's pane, in the window, not hidden.
    private static func terminalShows(_ s: Split) -> Bool {
        guard let pane = live(s), pane.stripModel.selectedID?.rawValue == s.tab.id, let content = pane.currentContent, content.isTerminal else { return false }
        let view = content.view
        return view.window != nil && view.isDescendant(of: pane.view) && !view.isHiddenOrHasHiddenAncestor
    }

    /// The keyboard is in the split's pane.
    private static func keyboardIsInPane(_ s: Split) -> Bool {
        guard let pane = live(s), let responder = pane.view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: pane.view)
    }

    private static func focusReport(_ s: Split) -> String {
        let workspace = s.workspace, pane = live(s)
        var text = "focus \(workspace.focus.state.pane ?? "nil"), pane \(s.key), layout focus \(workspace.layoutModel.focusedPane.map { "\($0)" } ?? "nil"), "
        text += "closing \(workspace.layoutModel.isClosing(s.pane.layoutPaneID)), topology has it \(workspace.focus.currentState().topology.contains(pane: s.key)), "
        text += "the window holds the pane \(pane != nil), the same object as before Cmd-W \(pane === s.pane), "
        text += "it is the focused pane \(pane != nil && s.services.windows.active?.focusedPane === pane), in the window \(pane?.view.window != nil), "
        text += "strip \(pane?.orderedIDs.map(\.rawValue) ?? []), selected \(pane?.stripModel.selectedID?.rawValue ?? "nil"), tab \(s.tab.id), "
        text += "terminal shows \(terminalShows(s)), keyboard in the pane \(keyboardIsInPane(s))"
        return text
    }

    /// From the release of the daemon's read: when the question shows and when the terminal's view is in the pane again
    /// (a harness timing loop, as `measureCmdWToEmptiedPaneGone`: a main-actor poll sees the state between two turns,
    /// so a terminal seen with the question is there in the take-back's turn or the first turn after it). Prints the
    /// two times in milliseconds ("none": not inside 5 s) and which pane object the window holds; it asserts nothing.
    private static func measureTakeBack(_ s: Split) async throws {
        let start = ContinuousClock.now
        func ms() -> Double { let d = ContinuousClock.now - start; return Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1e3 }
        var asked: Double?, terminal: Double?
        while asked == nil || terminal == nil, ContinuousClock.now - start < .seconds(5) {
            if asked == nil, question() != nil { asked = ms() }
            if terminal == nil, asked != nil, terminalShows(s) { terminal = ms() }
            if asked == nil || terminal == nil { try await Task.sleep(for: .microseconds(250)) } // harness timing loop
        }
        func text(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "none" }
        let after = asked.flatMap { asked in terminal.map { $0 - asked } }
        print("CLOSE-TAKE-BACK pane_object=\(live(s) === s.pane ? "same" : "new") question_ms=\(text(asked)) terminal_ms=\(text(terminal)) terminal_after_question_ms=\(text(after))")
    }

    /// The pane is in its window's shown layout.
    private static func shown(_ s: Split) -> Bool {
        s.workspace.layoutModel.screens.contains { $0.layout.contains(s.pane.layoutPaneID) }
    }

    /// The pane is in the daemon's tree.
    private static func inDaemon(_ s: Split) -> Bool {
        s.store.workspaces.contains { $0.screens.contains { $0.panes.contains { $0.handle == s.handle } } }
    }

    /// A few main-actor turns (a test harness bound).
    private static func turns() async throws { try await Task.sleep(for: .milliseconds(300)) }

    /// Waits until the daemon names `program` as the terminal's foreground program (nil: its shell only).
    private static func waitRunning(_ program: String?, _ s: Split) async throws {
        var last = "no answer"
        for _ in 0..<100 {
            if let answer = await s.connection.readProcessInfo(s.tab.surface, timeout: .seconds(1)) {
                if answer.runningProgram == program { return }
                last = answer.runningProgram ?? "its shell only"
            }
            try await Task.sleep(for: .milliseconds(100)) // test harness polling the daemon
        }
        Issue.record("the terminal never ran \(program ?? "its shell only") in front (last: \(last))")
    }

    private static func question() -> CmuxDialogCenter.Record? {
        CmuxDialogCenter.shared.records.first { $0.spec.identifier == "cmux.dialog.confirmation" }
    }
}
