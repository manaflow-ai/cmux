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
            try await PinnedPageTests.until({ Self.question() != nil }, report: { "no close question" })
            #expect(Self.shown(s), "the pane is not back on screen while its question shows")
            #expect(s.pane.orderedIDs.map(\.rawValue).contains(s.tab.id), "the tab is not back in its strip while its question shows")
            try await PinnedPageTests.until({ s.services.windows.active?.focusedPane === s.pane },
                                            report: {
                let workspace = s.pane.workspace
                return "the focus did not come back to the pane the question asks about: focus \(workspace?.focus.state.pane ?? "nil"), pane \(s.pane.paneKey), "
                    + "layout focus \(workspace?.layoutModel.focusedPane.map { "\($0)" } ?? "nil"), closing \(workspace?.layoutModel.isClosing(s.pane.layoutPaneID) == true), "
                    + "topology has it \(workspace?.focus.currentState().topology.contains(pane: s.pane.paneKey) == true)"
            })
            _ = CmuxDialogCenter.shared.press(try #require(Self.question()).id, button: "cancel")
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(s.tab.id) }, report: { "the cancelled close still asks" })
            try await Self.turns()
            #expect(Self.shown(s), "Cancel did not keep the pane")
            #expect(Self.inDaemon(s), "Cancel did not keep the pane in the daemon's tree")
            try await Self.waitRunning("sleep", s)
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
            try await PinnedPageTests.until({ Self.shown(s) && s.pane.orderedIDs.map(\.rawValue).contains(s.tab.id) },
                                            report: { "the pane did not come back with the program's tab: shown \(Self.shown(s)), strip \(s.pane.orderedIDs)" })
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
        let pane: PaneController
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
        let s = Split(services: services, connection: connection, store: store, pane: pane, handle: model.handle, tab: tab)
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

    /// The pane is in its window's shown layout.
    private static func shown(_ s: Split) -> Bool {
        guard let workspace = s.pane.workspace else { return false }
        return workspace.layoutModel.screens.contains { $0.layout.contains(s.pane.layoutPaneID) }
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
