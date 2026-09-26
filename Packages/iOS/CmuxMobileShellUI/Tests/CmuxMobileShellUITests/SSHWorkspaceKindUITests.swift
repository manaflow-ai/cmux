import CmuxMobileShell
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShellUI

/// Round 3 UI values (PRD D31, D32): the `+` menu's kinds and the grouped
/// tab switcher for tmux and cmux-tui workspaces.
@Suite struct SSHWorkspaceKindUITests {
    @Test func kindOptionsCarryTitlesAndUnavailableReasons() {
        let options = [
            MobileSSHKindAvailability(kind: .cmuxTUI, needsInstall: true),
            MobileSSHKindAvailability(kind: .tmux, unavailableReason: "tmux is not installed on this computer."),
            MobileSSHKindAvailability(kind: .shell),
        ].map(WorkspaceCreateKindOption.init)
        #expect(options.map(\.kind.sshNewItemTitle) == ["New cmux-tui Workspace", "New tmux Session", "New Shell"])
        #expect(options.map(\.unavailableReason) == [nil, "tmux is not installed on this computer.", nil])

        // One SSH computer: `+` shows kinds; several computers: it asks
        // which first, and an SSH target carries its kinds as a submenu.
        let single = WorkspaceListNewWorkspaceMenuValue(canCreate: true, canCreateGroup: false, sshKinds: options)
        #expect(!single.asksForComputer)
        #expect(single.sshKinds.count == 3)
    }

    @Test func groupedLayoutReachesThePickerAndNamesItsActions() {
        let row = MobileSSHTabRow(id: "cmux-ssh-x~tmux:work/%1", title: "Pane 1", paneLabel: nil, startsPane: false)
        let layout = MobileSSHTabLayout(
            kind: .tmux,
            sections: [MobileSSHTabSection(id: "0", title: "0: zsh", rows: [row], actions: [.splitPane])]
        )
        let terminal = MobileTerminalPreview(id: .init(rawValue: row.id), name: "0:zsh · pane 1")
        let value = TerminalPickerMenuValue(
            liveTerminals: [terminal],
            snapshotRows: [],
            selectedID: terminal.id,
            canCreateWorkspace: true,
            hasActiveBrowser: false,
            sshTabLayout: layout
        )
        #expect(value.sshTabLayout == layout)
        #expect(value.checkedRowID == TerminalPickerMenuRow.ID.terminal(terminal.id))
        #expect(value.selectedName == "0:zsh · pane 1")
        #expect(layout.newTerminalTitle == "New Window")
        #expect(layout.sections.first?.actions.map(\.title) == ["Split Pane"])

        var tui = layout
        tui.kind = MobileSSHWorkspaceKind.cmuxTUI
        #expect(tui.newTerminalTitle == "New Screen")
        #expect(MobileSSHSectionAction.allCases.map(\.title) == ["New Tab", "Split Pane"])
        #expect(MobileSSHSectionAction.splitPane.accessibilityIdentifier(section: "3") == "MobileSSHSectionAction-splitPane-3")
        // A different layout is a different menu value (the menu rebuilds).
        let flat = TerminalPickerMenuValue(
            liveTerminals: [terminal],
            snapshotRows: [],
            selectedID: terminal.id,
            canCreateWorkspace: true,
            hasActiveBrowser: false
        )
        #expect(flat != value)
    }
}
