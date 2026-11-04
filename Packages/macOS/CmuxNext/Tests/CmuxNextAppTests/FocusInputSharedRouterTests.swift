import CmuxNextFocus
import Foundation
import Testing

/// R-INPUT stage S2, step B: every window's focus machine keeps its focus in the app's one input router (``FocusInput``,
/// `cmux_input_*`) under a window key of its own. Each machine must reduce exactly as a machine alone does (byte-equal
/// replies: the same state and effects after every event), whatever another window does in the same router between its
/// events; a new machine never meets a freed one's focus; and every request the machine makes goes through the input handle
/// (review of #35641: the C ABI test did not call every export, and a refused checkpoint must leave the state as it was).
struct FocusInputSharedRouterTests {
    /// Two terminal panes and a browser pane in one workspace.
    private static func topology(_ workspace: String) -> FocusTopology {
        FocusTopology(workspace: workspace, panes: [
            .init(id: "a", tabs: [.init(id: "a-tab", kind: .terminal)], selected: "a-tab"),
            .init(id: "b", tabs: [.init(id: "b-tab", kind: .terminal), .init(id: "b-page", kind: .browser)], selected: "b-tab"),
            .init(id: "c", tabs: [.init(id: "c-page", kind: .browser)], selected: "c-page"),
        ])
    }

    /// A sequence that runs focus moves, a selection, a person's click report, an intent with its wait and landing, the
    /// address bar memory, a topology change and a close-focus policy.
    private static let events: [FocusEvent] = [
        .topology(topology("w")),
        .focusPane("a", source: .programmatic),
        .focusPane("b", source: .mouse),
        .selectTab(pane: "b", tab: "b-page", workspace: "w", source: .keyboard),
        .focusTarget(.addressBar, source: .keyboard),
        .responder(.content(pane: "c"), source: .mouse),
        .beginIntent,
        .focusPane("a", source: .cli),
        .topology(FocusTopology(workspace: "w", panes: [
            .init(id: "a", tabs: [.init(id: "a-tab", kind: .terminal)], selected: "a-tab"),
            .init(id: "c", tabs: [.init(id: "c-page", kind: .browser)], selected: "c-page"),
        ])),
        .focusPane("c", source: .palette),
    ]

    @Test func aMachineInTheSharedRouterReducesAsAMachineAlone() throws {
        let shared = FocusInput()
        let alone = FocusMachine(), inRouter = FocusMachine(input: shared), other = FocusMachine(input: shared)
        var aloneState = FocusState(), routerState = FocusState(), otherState = FocusState()
        _ = other.send(.topology(Self.topology("other")), into: &otherState)
        for (step, event) in Self.events.enumerated() {
            let expected = alone.send(event, into: &aloneState)
            // Another window of the same router acts between this window's events.
            _ = other.send(.focusPane(step.isMultiple(of: 2) ? "b" : "c", source: .mouse), into: &otherState)
            let got = inRouter.send(event, into: &routerState)
            #expect(got?.changed == expected?.changed && got?.effects == expected?.effects
                    && got?.omnibarReturn == expected?.omnibarReturn && got?.returnsToOmnibar == expected?.returnsToOmnibar,
                    "step \(step) (\(event)): the shared router's reply differs from a machine alone")
            #expect(routerState == aloneState, "step \(step) (\(event)): the shared router's state differs from a machine alone")
        }
        #expect(inRouter.checkpoint().matches(alone.checkpoint()), "the shared router's checkpoint differs from a machine alone")
        #expect(inRouter.recentPanes() == alone.recentPanes())
        #expect(inRouter.remembered() == alone.remembered())
        #expect(otherState.topology.workspace == "other", "the other window's state took this window's events")
    }

    /// Each machine has a window key of its own in the router: a new machine never meets the focus of one freed before
    /// it (the app reuses a window id when it restores a closed window), and the window still open keeps its own.
    @Test func aNewMachineNeverMeetsAFreedMachinesFocus() throws {
        let shared = FocusInput()
        let kept = FocusMachine(input: shared)
        var keptState = FocusState()
        _ = kept.send(.topology(Self.topology("kept")), into: &keptState)
        _ = kept.send(.focusPane("b", source: .mouse), into: &keptState)
        do {
            let closing = FocusMachine(input: shared)
            var closingState = FocusState()
            _ = closing.send(.topology(Self.topology("closing")), into: &closingState)
            _ = closing.send(.focusPane("c", source: .mouse), into: &closingState)
        }
        let fresh = FocusMachine(input: shared)
        #expect(fresh.recentPanes().isEmpty, "a new machine met a freed machine's focus history: \(fresh.recentPanes())")
        #expect(fresh.remembered().isEmpty, "a new machine met a freed machine's remembered panes: \(fresh.remembered())")
        _ = kept.send(.focusPane("a", source: .keyboard), into: &keptState)
        #expect(kept.recentPanes(in: "kept").prefix(2) == ["a", "b"], "the window still open lost its focus history: \(kept.recentPanes(in: "kept"))")
    }

    /// Every request a machine makes reaches the router through the input handle: the close-focus policy, the Close Tab
    /// aim (pane emptied, pane moved, frame presented, aimed at), the focus history, the remembered panes and the journal
    /// checkpoint, each with the answer a machine alone gives. A checkpoint that does not decode is refused and leaves the
    /// state as it was.
    @Test func everyRequestGoesThroughTheInputHandle() throws {
        let alone = FocusMachine(), inRouter = FocusMachine(input: FocusInput())
        var answers: [String: [String]] = [:]
        for (name, machine) in [("alone", alone), ("router", inRouter)] {
            var state = FocusState(), seen: [String] = []
            _ = machine.send(.topology(Self.topology("w")), into: &state)
            _ = machine.send(.focusPane("b", source: .mouse), into: &state)
            _ = machine.send(.focusPane("a", source: .mouse), into: &state)
            machine.setCloseFocus(mostRecent: true)
            seen.append("history \(machine.recentPanes(in: "w"))")
            seen.append("remembered \(machine.remembered().sorted { $0.key < $1.key })")
            // The Close Tab aim as `PaneCloseAim` documents it: a close empties "a", the focus moves to "b", its frame shows.
            let aim = PaneCloseAim(machine: machine)
            aim.paneEmptied("a", by: .init(time: 10, isKey: true, isRepeat: false))
            _ = machine.send(.focusPane("b", source: .programmatic), into: &state)
            let move = aim.paneMoved(from: "a")
            aim.presented(move, at: 10.02)
            seen.append("before the frame \(aim.aimsAtEmptiedPane(.init(time: 10.01, isKey: true, isRepeat: false)))")
            seen.append("after the frame \(aim.aimsAtEmptiedPane(.init(time: 10.30, isKey: true, isRepeat: false)))")
            let before = machine.checkpoint()
            seen.append("bad checkpoint refused \(machine.restore(FocusCheckpoint(json: "{ not json")) == nil)")
            seen.append("state kept \(machine.checkpoint().matches(before))")
            let restored = try #require(machine.restore(before), "\(name): the machine's own checkpoint was refused")
            seen.append("restored \(String(describing: restored.typingTab))")
            answers[name] = seen
        }
        #expect(answers["router"] == answers["alone"], "the input handle answered differently from a machine alone: \(answers)")
        let router = answers["router"] ?? []
        #expect(router.contains("before the frame true") && router.contains("after the frame false"),
                "the Close Tab aim did not answer as PaneCloseAim documents: \(router)")
        #expect(router.contains("bad checkpoint refused true") && router.contains("state kept true"),
                "a checkpoint that does not decode was taken or changed the state: \(router)")
    }
}
