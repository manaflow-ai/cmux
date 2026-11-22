import CmuxNextFocus
import Testing

/// SPACE SWITCH 4: where the keys go after a sidebar row press that shows another workspace, per pane kind.
///
/// Before, the press made the list the first responder inside the mouse-down (`.responder(.sidebar, source: .mouse)`),
/// then the switch changed the topology, and the focus model put the keyboard on the new workspace's content
/// (`cmux-focus-core` `apply_topology`: a workspace change leaves a sidebar target that no key made). While a page holds
/// the key, the press now sends the switch alone (`SidebarSwitchPressKeepsPageKeyTests`). These tests hold the two
/// sequences against each other in the focus model: the keyboard ends on the same content of the NEW workspace, and
/// the switch asks AppKit for that responder. The level is the focus model, not typed text in a real pane.
struct SidebarSwitchPressFocusTests {
    /// The kinds of the old workspace's tab whose content is a page window (the press takes its new path with them).
    nonisolated static let pageKinds: [FocusTopology.Kind] = [.browser, .agent]
    /// The kinds of the new workspace's tab.
    nonisolated static let kinds: [FocusTopology.Kind] = [.terminal, .browser, .agent, .page, .conversation]

    /// Workspace `name`: one pane with one tab of `kind`.
    private static func workspace(_ name: String, _ kind: FocusTopology.Kind) -> FocusTopology {
        FocusTopology(workspace: name, panes: [.init(id: "\(name)-pane", tabs: [.init(id: "\(name)-tab", kind: kind)], selected: "\(name)-tab")])
    }

    /// What has the keyboard when workspace `name`'s tab of `kind` does.
    private static func content(_ kind: FocusTopology.Kind, of name: String) -> FocusState.Resolved {
        let (pane, tab) = ("\(name)-pane", "\(name)-tab")
        switch kind {
        case .terminal: return .terminal(pane: pane, tab: tab)
        case .browser: return .browserPage(pane: pane, tab: tab)
        case .agent: return .agentPage(pane: pane, tab: tab)
        case .page: return .page(pane: pane, tab: tab)
        case .conversation: return .conversation(pane: pane, tab: tab)
        case .other: return .emptyPane(pane: pane)
        }
    }

    /// A window that shows workspace `old`, the person's click in its content.
    private func window(showing kind: FocusTopology.Kind) -> (FocusMachine, FocusState) {
        let machine = FocusMachine()
        var state = FocusState()
        _ = machine.send(.topology(Self.workspace("old", kind)), into: &state)
        _ = machine.send(.focusPane("old-pane", source: .mouse), into: &state)
        return (machine, state)
    }

    @Test(arguments: pageKinds, kinds)
    func theKeyboardIsOnTheNewWorkspacesContentAsItWasWithTheListFirst(_ old: FocusTopology.Kind, _ new: FocusTopology.Kind) {
        let want = Self.content(new, of: "new")

        // Before: the list as the first responder inside the mouse-down, then the switch.
        let (earlier, start) = window(showing: old)
        var was = start
        #expect(was.resolved == Self.content(old, of: "old"), "the start state is wrong: \(was.resolved)")
        _ = earlier.send(.responder(.sidebar, source: .mouse), into: &was)
        #expect(was.resolved == .sidebar, "the list did not take the keyboard in the old sequence: \(was.resolved)")
        _ = earlier.send(.topology(Self.workspace("new", new)), into: &was)
        #expect(was.resolved == want, "the old sequence left the keyboard on \(was.resolved)")

        // Now: the switch alone.
        let (machine, same) = window(showing: old)
        var now = same
        let reduction = machine.send(.topology(Self.workspace("new", new)), into: &now)
        #expect(now.resolved == want, "after the press the keyboard is on \(now.resolved), not on the new workspace's \(new) tab")
        #expect(now.resolved == was.resolved && now.typingTab == was.typingTab,
                "the keys go to \(now.resolved) (typing tab \(now.typingTab ?? "none")); they went to \(was.resolved) (\(was.typingTab ?? "none"))")
        #expect(reduction?.effects.contains(.moveResponder(want)) == true,
                "the switch did not ask for the new content as the responder: \(String(describing: reduction?.effects))")
    }

    /// The list keeps the keyboard through a switch only when a key put it there (arrow keys in the list): that case
    /// needs the shell window key, where the press keeps its old path. Held here so the rule above stays narrow.
    @Test func aListThatAKeyFocusedKeepsTheKeyboardThroughASwitch() {
        let (machine, start) = window(showing: .terminal)
        var state = start
        _ = machine.send(.responder(.sidebar, source: .keyboard), into: &state)
        _ = machine.send(.topology(Self.workspace("new", .terminal)), into: &state)
        #expect(state.resolved == .sidebar, "a keyboard-focused list lost the keyboard at a switch: \(state.resolved)")
    }
}
