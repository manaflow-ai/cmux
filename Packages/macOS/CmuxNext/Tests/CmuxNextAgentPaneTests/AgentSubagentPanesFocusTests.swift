import Testing
@testable import CmuxNextAgentPane

/// A click on a subagent whose pane is still opening without focus (each new subagent opens a pane
/// on its own, `useOpenNewSubagents`) used to do nothing: ``AgentSubagentPanes/begin(_:focus:chat:)``
/// dropped the repeat because that subagent's open was the one running, and ``open`` still said it
/// opened, so the page did not show the subagent in place either. The pane now takes focus once it
/// has opened.
@Suite
@MainActor
struct AgentSubagentPanesFocusTests {
    /// Hooks whose `place` holds its callbacks, as a pane still moving into place does.
    final class Recorder {
        var focused: [(key: String, script: Bool)] = []
        var created: (@MainActor (String) -> Void)?
        var finished: (@MainActor (Bool) -> Void)?
        var open: Set<String> = []

        var hooks: AgentSubagentPanes.Hooks {
            AgentSubagentPanes.Hooks(
                isOpen: { [unowned self] key in self.open.contains(key) },
                focus: { [unowned self] key, script in self.focused.append((key, script)) },
                place: { [unowned self] _, _, created, finished in
                    self.created = created
                    self.finished = finished
                    return true
                },
                again: { _ in }
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
        #expect(recorder.focused.map(\.key) == ["tab-explore"])
        #expect(recorder.focused.first?.script == false, "the person asked for it")
    }

    @Test func anUnfocusedOpenAloneTakesNoFocus() {
        let panes = AgentSubagentPanes()
        let recorder = Recorder()
        #expect(panes.open("explore", focus: false, chat: "chat", hooks: recorder.hooks))
        recorder.land("tab-explore")
        #expect(recorder.focused.isEmpty)
    }
}
