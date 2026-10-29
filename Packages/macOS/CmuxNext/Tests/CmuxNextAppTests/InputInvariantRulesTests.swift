import CmuxNextFocus
import CmuxNextInputModel
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextInvariants
#endif
import Testing
@testable import CmuxNextApp

/// The input rules as the invariant registry declares them (InputVerificationService.worldRules): one world check per
/// pass, each declared rule taking its own id's share of it, W4 only where the harness waited, and the windows the
/// check skips (a pane that does not present its target yet, or whose content is owed) waited on by W9, not checked.
struct InputInvariantRulesTests {
    private func window(_ id: String, _ resolved: FocusState.Resolved, isKey: Bool, responder: FocusEvent.Responder,
                        ghostty: [String] = [], presented: [String: String] = ["pane_a": "tab_t"],
                        owed: [String]? = nil) -> InputObservation.Window {
        var model = FocusState()
        model.resolved = resolved
        model.underlying = resolved
        model.windowKey = isKey
        model.pane = "pane_a"
        model.topology = FocusTopology(workspace: "ws", panes: [FocusTopology.Pane(id: "pane_a", tabs: [FocusTopology.Tab(id: "tab_t", kind: .terminal)],
                                                                                   selected: "tab_t")], screens: [])
        return InputObservation.Window(id: id, model: model, responder: responder, isKey: isKey, layoutFocus: "pane_a",
                                       ghosttyFocused: ghostty, presented: presented, visible: true, owed: owed)
    }

    private var observations: [InputObservation] {
        let terminal = FocusState.Resolved.terminal(pane: "pane_a", tab: "tab_t")
        return [
            // In sync.
            InputObservation(windows: [window("w1", terminal, isKey: true, responder: .content(pane: "pane_a"), ghostty: ["tab_t"])],
                             keyWindow: .window("w1"), paletteOpen: false, activeWindow: "w1",
                             context: FocusState.Context(terminal: true), appActive: true),
            // Ghostty focus in a window that is not key, no key window while active, the context unpublished.
            InputObservation(windows: [window("w1", terminal, isKey: false, responder: .windowOrNone, ghostty: ["tab_t"]),
                                       window("w2", .none, isKey: false, responder: .windowOrNone, presented: [:])],
                             keyWindow: .none, paletteOpen: true, activeWindow: "w2", context: FocusState.Context(), appActive: true),
        ]
    }

    @Test func everyIDTheWorldCheckReportsIsADeclaredRule() {
        for observation in observations {
            let reported = Set(InputInvariants.world(observation).violations.map(\.invariant))
            #expect(reported.isSubset(of: Set(InputInvariants.worldRules)), "undeclared: \(reported.subtracting(InputInvariants.worldRules))")
        }
    }

    @Test func aWindowThatDoesNotPresentItsTargetIsWaitedOnNotChecked() {
        let terminal = FocusState.Resolved.terminal(pane: "pane_a", tab: "tab_t")
        let pending = InputObservation(windows: [window("w1", terminal, isKey: true, responder: .windowOrNone, presented: ["pane_a": "tab_other"])],
                                       keyWindow: .window("w1"), paletteOpen: false, activeWindow: "w1",
                                       context: FocusState.Context(terminal: true), appActive: true)
        let result = InputInvariants.world(pending)
        #expect(result.unsettled == ["w1"])
        #expect(!result.violations.contains { $0.invariant == .responderMatches }, "W1 waits for the presentation (W9)")
    }

    @Test func aPaneWhoseContentIsOwedIsWaitedOnNotChecked() {
        // A Ctrl-` stand-in's page comes after its first frame commits: the pane presents the tab, its page is owed.
        let page = FocusState.Resolved.browserPage(pane: "pane_a", tab: "tab_t")
        let owed = InputObservation(windows: [window("w1", page, isKey: true, responder: .windowOrNone, owed: ["pane_a"])],
                                    keyWindow: .window("w1"), paletteOpen: false, activeWindow: "w1",
                                    context: FocusState.Context(browser: true), appActive: true)
        let result = InputInvariants.world(owed)
        #expect(result.unsettled == ["w1"], "an owed page is level state: the window is unsettled, W9 bounds the wait")
        #expect(!result.violations.contains { [.responderMatches, .presentedMatchesSelection].contains($0.invariant) })
        var landed = owed
        landed.windows[0].owed = nil
        #expect(InputInvariants.world(landed).unsettled.isEmpty, "once the page is made, the window is checked")
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @MainActor @Test func theDeclaredRulesReportWhatOneWorldCheckFindsAndW4OnlyOnACheck() throws {
        let fixture = WorldFixture(observations[1])
        let registry = InvariantRegistry(mode: .on) { _, _ in }
        let world: @MainActor (InvariantPass) -> InputInvariants.WorldResult? = { [fixture] pass in
            pass.memo("input.world") {
                fixture.builds += 1
                return InputInvariants.world(fixture.current)
            }
        }
        for rule in InputVerificationService.worldRules(world) { registry.declare(rule) }
        registry.noteAction("pane.split", origin: "key")
        registry.runTurn()
        #expect(fixture.builds == 1, "every rule of the pass shares one world check")
        let expected = Set(InputInvariants.world(fixture.current).violations.filter { $0.invariant != .chromiumMatches }.map(\.invariant.rawValue))
        #expect(!expected.isEmpty)
        #expect(Set(registry.ledger.since(0).violations.map(\.id.rawValue)) == expected)
        // W4 (Chromium focus, an async peer) is checked only on demand, where the harness already waited.
        let page = FocusState.Resolved.browserPage(pane: "pane_a", tab: "tab_t")
        var w4 = window("w1", page, isKey: true, responder: .windowOrNone)
        w4.childWindowTabs = ["tab_t"]
        fixture.current = InputObservation(windows: [w4], keyWindow: .childPage(window: "w1"), paletteOpen: false, activeWindow: "w1",
                                   context: FocusState.Context(browser: true), appActive: true)
        let before = registry.ledger.lastSeq
        registry.noteAction("tab.select", origin: "key")
        registry.runTurn()
        #expect(!registry.ledger.since(before).violations.contains { $0.id == "W4" }, "no W4 inside a turn")
        let found = registry.checkNow()
        #expect(found.contains { $0.id == "W4" }, "W4 on a check: \(found.map(\.id))")
    }
    #endif
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The observation the rules read, and how many world checks a pass built.
@MainActor
private final class WorldFixture {
    var current: InputObservation
    var builds = 0

    init(_ current: InputObservation) {
        self.current = current
    }
}
#endif
