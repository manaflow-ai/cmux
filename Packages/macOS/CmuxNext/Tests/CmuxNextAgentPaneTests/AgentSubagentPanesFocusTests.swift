import Testing
@testable import CmuxNextAgentPane

/// A click on a subagent whose pane is still opening without focus (each new subagent opens a pane
/// on its own, `useOpenNewSubagents`) used to do nothing: ``AgentSubagentPanes/begin(_:focus:chat:)``
/// dropped the repeat because that subagent's open was the one running, and ``open`` still said it
/// opened, so the page did not show the subagent in place either. The pane now takes focus once it
/// has opened, unless the person did something else first or it lands too late (projects-7b's review
/// of #22487: an owed focus landed up to 20 s after the click, over whatever the person did since).
@Suite
@MainActor
struct AgentSubagentPanesFocusTests {
    /// Hooks whose `place` holds its callbacks, as a pane still moving into place does.
    @MainActor
    final class Recorder {
        var focused: [(key: String, script: Bool)] = []
        var created: (@MainActor (String) -> Void)?
        var finished: (@MainActor (Bool) -> Void)?
        var open: Set<String> = []
        var now = ContinuousClock.now
        /// What a click, key press or focus change calls while an owed focus waits; nil when no one watches.
        var acted: (@MainActor () -> Void)?
        var stops = 0
        var again: [AgentSubagentPanes.Request] = []

        var hooks: AgentSubagentPanes.Hooks {
            AgentSubagentPanes.Hooks(
                isOpen: { [unowned self] key in self.open.contains(key) },
                focus: { [unowned self] key, script in self.focused.append((key, script)) },
                place: { [unowned self] _, _, created, finished in
                    self.created = created
                    self.finished = finished
                    return true
                },
                again: { [unowned self] request in self.again.append(request) },
                now: { [unowned self] in self.now },
                watchUser: { [unowned self] acted in
                    self.acted = acted
                    return { [unowned self] in
                        self.acted = nil
                        self.stops += 1
                    }
                }
            )
        }

        /// The held open lands: its tab exists, then the move ends.
        func land(_ key: String) {
            open.insert(key)
            created?(key)
            finished?(true)
        }
    }

    @Test func aClickWhileTheSubagentsPaneOpensUnfocusedFocusesItOnceOpen() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        #expect(panes.open("explore", focus: true, chat: "chat", hooks: recorder.hooks))
        #expect(recorder.focused.isEmpty, "nothing to focus before the tab exists")
        recorder.land("tab-explore")
        #expect(recorder.focused.map({ $0.key }) == ["tab-explore"])
        #expect(recorder.focused.first?.script == false, "the person asked for it")
    }

    @Test func anUnfocusedOpenAloneTakesNoFocus() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        recorder.land("tab-explore")
        #expect(recorder.focused.isEmpty)
    }

    @Test func aSecondBackgroundTabDoesNotStealFocus() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        recorder.land("tab-explore")
        #expect(panes.open("plan", focus: false, chat: "chat", hooks: recorder.hooks))
        recorder.land("tab-plan")
        #expect(recorder.focused.isEmpty, "Cmd-clicking another subagent kept the source focused")
    }

    @Test func aClickKeyPressOrFocusChangeAfterTheClickCancelsTheOwedFocus() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        #expect(recorder.acted == nil, "nothing is owed yet, so nothing watches")
        #expect(panes.open("explore", focus: true, chat: "chat", hooks: recorder.hooks))
        recorder.acted?()
        #expect(recorder.stops == 1, "the first action ends the watch")
        recorder.land("tab-explore")
        #expect(recorder.focused.isEmpty, "the person's latest action wins")
    }

    @Test func anOwedFocusExpiresAfterItsBound() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        #expect(panes.open("explore", focus: true, chat: "chat", hooks: recorder.hooks))
        recorder.now += AgentSubagentPanes.focusBound + .milliseconds(1)
        recorder.land("tab-explore")
        #expect(recorder.focused.isEmpty, "a pane that lands late takes no focus")
        #expect(recorder.stops == 1, "the watch ends with the open")
    }

    @Test func anOwedFocusWithinItsBoundStillLands() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        #expect(panes.open("explore", focus: true, chat: "chat", hooks: recorder.hooks))
        recorder.now += AgentSubagentPanes.focusBound
        recorder.land("tab-explore")
        #expect(recorder.focused.map({ $0.key }) == ["tab-explore"])
        #expect(recorder.acted == nil, "no watch outlives the open")
    }

    @Test func aRepeatClickRestartsTheBound() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        #expect(panes.open("explore", focus: true, chat: "chat", hooks: recorder.hooks))
        recorder.now += .seconds(1.5)
        #expect(panes.open("explore", focus: true, chat: "chat", hooks: recorder.hooks))
        recorder.now += .seconds(1.5)
        recorder.land("tab-explore")
        #expect(recorder.focused.map({ $0.key }) == ["tab-explore"], "the latest click is the one that counts")
    }

    @Test func aWaitingFocusedRequestYieldsToALaterAction() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        #expect(panes.open("plan", focus: true, chat: "chat", hooks: recorder.hooks))
        #expect(recorder.acted != nil, "a focus that waits its turn is owed too")
        recorder.acted?()
        recorder.land("tab-explore")
        #expect(recorder.again.map({ $0.agent }) == ["plan"])
        #expect(recorder.again.first?.focus == false, "the person's latest action wins")
    }

    @Test func aWaitingFocusedRequestExpiresAfterItsBound() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        #expect(panes.open("plan", focus: true, chat: "chat", hooks: recorder.hooks))
        recorder.now += AgentSubagentPanes.focusBound + .milliseconds(1)
        recorder.land("tab-explore")
        #expect(recorder.again.first?.focus == false, "a pane whose turn comes late opens without focus")
        #expect(recorder.acted == nil, "nothing is owed any more, so nothing watches")
    }

    @Test func aWaitingFocusedRequestWithinItsBoundKeepsFocus() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        #expect(panes.open("plan", focus: true, chat: "chat", hooks: recorder.hooks))
        recorder.now += AgentSubagentPanes.focusBound
        recorder.land("tab-explore")
        #expect(recorder.again.first?.focus == true)
    }
}
