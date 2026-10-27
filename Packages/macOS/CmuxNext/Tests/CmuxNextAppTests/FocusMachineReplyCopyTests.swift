import CmuxNextFocus
import Testing

/// The focus machine's C ABI calls after p10-stability-074: requests lend their buffers only for the call, and
/// replies and string lists are copied out (bounds-checked) before the next call on the handle. These run every
/// path whose pointer handling changed: topology, an event, an event with a tab list, the history and remembered
/// lists, a checkpoint round trip and the static changesView rule.
struct FocusMachineReplyCopyTests {
    private static let topology = FocusTopology(workspace: "w1", panes: [
        .init(id: "p1", tabs: [.init(id: "t1", surface: "s1", kind: .terminal)], selected: "t1"),
        .init(id: "p2", tabs: [.init(id: "t2", kind: .browser), .init(id: "t3", kind: .terminal)], selected: "t2"),
    ])

    private func focused(_ pane: String) throws -> (FocusMachine, FocusState) {
        let machine = FocusMachine()
        var state = FocusState()
        _ = try #require(machine.send(.topology(Self.topology), into: &state))
        _ = try #require(machine.send(.focusPane(pane, source: .keyboard), into: &state))
        return (machine, state)
    }

    @Test func focusReplyStringsAreCopiedIntoTheState() throws {
        let (_, state) = try focused("p2")
        #expect(state.topology == Self.topology)
        #expect(state.pane == "p2")
    }

    @Test func eventWithATabListReachesTheMachine() throws {
        let (machine, initial) = try focused("p1")
        var state = initial
        _ = try #require(machine.send(.dragBegan(tabs: ["t2", "t3"], pane: "p2"), into: &state))
        #expect(state.isDragging)
        _ = try #require(machine.send(.dragEnded(.cancelled), into: &state))
        #expect(!state.isDragging)
    }

    @Test func historyAndRememberedListsAreReadForAnotherWorkspace() throws {
        let (machine, initial) = try focused("p1")
        var state = initial
        _ = try #require(machine.send(.focusPane("q1", workspace: "w2", source: .keyboard), into: &state))
        _ = try #require(machine.send(.focusPane("q2", workspace: "w2", source: .keyboard), into: &state))
        #expect(machine.recentPanes(in: "w2") == ["q2", "q1"])
        #expect(machine.remembered()["w2"] == "q2")
        #expect(machine.recentPanes(in: "none").isEmpty)
    }

    @Test func checkpointRestoresTheSameState() throws {
        let (machine, state) = try focused("p2")
        let checkpoint = machine.checkpoint()
        let restored = try #require(FocusMachine().restore(checkpoint))
        #expect(restored.pane == state.pane)
        #expect(restored.topology == state.topology)
        #expect(FocusMachine().restore(FocusCheckpoint(json: "not json")) == nil)
    }

    @Test func changesViewReadsTheEventAndItsList() {
        #expect(FocusEvent.focusPane("p1", source: .mouse).changesView)
        #expect(FocusEvent.dragEnded(.dropped(tabs: ["t1", "t2"], awayFrom: "p1")).changesView)
        #expect(!FocusEvent.dragEnded(.cancelled).changesView)
        #expect(!FocusEvent.windowKey(true).changesView)
    }
}
