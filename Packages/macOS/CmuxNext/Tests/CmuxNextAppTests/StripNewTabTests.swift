import CmuxNextActions
import Testing
@testable import CmuxNextApp

/// The tab strip's "+" opens an agent chat (Leo, 2026-10-04); Cmd-T keeps
/// `tabs.newTabKind`, and Option-click keeps its one-shot workspace override.
@Suite struct StripNewTabTests {
    @Test func plusOpensAnAgentChatOnItsPane() {
        var runs: [(ActionID, ActionInvocation)] = []
        StripNewTab.request(pane: "pane_a") { runs.append(($0, $1)) }
        #expect(runs.map(\.0) == ["palette.newAgentChat"])
        #expect(runs.first?.1.target == ActionTargetRef(kind: .pane, id: "pane_a"))
    }

    @Test func optionPlusRunsCmdTsKindWithTheOneShotWorkspaceOverride() {
        var runs: [(ActionID, ActionInvocation)] = []
        StripNewTab.request(pane: "pane_a", opensWorkspace: true) { runs.append(($0, $1)) }
        #expect(runs.map(\.0) == ["newTab.sameKind"])
        #expect(runs.first?.1["toggleWorkspace"]?.boolValue == true)
    }
}

/// The tab group editor's New Tab follows Cmd-T (coordinator decision
/// 2026-10-01): the kind of the group's selected tab, else its last tab,
/// else a terminal.
@Suite struct GroupNewTabTests {
    private func run(selected: String?, group: [String]) -> [(ActionID, ActionTargetRef?)] {
        var runs: [(ActionID, ActionTargetRef?)] = []
        StripNewTab.requestInGroup(selected: selected, groupTabs: group, pane: "pane_a") { runs.append(($0, $1.target)) }
        return runs
    }

    @Test func theGroupsSelectedTabDecides() {
        let runs = run(selected: "tab_b", group: ["tab_a", "tab_b", "tab_c"])
        #expect(runs.map(\.0) == ["newTab.sameKind"])
        #expect(runs.first?.1 == ActionTargetRef(kind: .tab, id: "tab_b"))
    }

    @Test func withTheSelectionOutsideTheGroupItsLastTabDecides() {
        let runs = run(selected: "tab_x", group: ["tab_a", "tab_c"])
        #expect(runs.map(\.0) == ["newTab.sameKind"])
        #expect(runs.first?.1 == ActionTargetRef(kind: .tab, id: "tab_c"))
    }

    @Test func anEmptyGroupGetsATerminalTab() {
        let runs = run(selected: nil, group: [])
        #expect(runs.map(\.0) == ["newSurface"])
        #expect(runs.first?.1 == ActionTargetRef(kind: .pane, id: "pane_a"))
    }

    @Test func optionNewTabInGroupCarriesTheOneShotWorkspaceOverride() {
        var runs: [ActionInvocation] = []
        StripNewTab.requestInGroup(selected: "tab_a", groupTabs: ["tab_a"], pane: "pane_a", opensWorkspace: true) {
            runs.append($1)
        }
        #expect(runs.first?["toggleWorkspace"]?.boolValue == true)
    }
}
