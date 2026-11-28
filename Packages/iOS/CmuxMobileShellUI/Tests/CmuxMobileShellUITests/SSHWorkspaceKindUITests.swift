import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
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

    /// Switching SSH hosts must replace `+`'s create action. The menu is
    /// `Equatable` on its value, and two hosts offer the same kinds, so the
    /// value carries the target host; otherwise SwiftUI kept the previous
    /// host's action and the first New Shell after a switch opened there.
    @MainActor @Test func switchingHostsInvalidatesTheNewWorkspaceMenu() {
        let options = [MobileSSHKindAvailability(kind: .shell)].map(WorkspaceCreateKindOption.init)
        let first = UUID()
        let second = UUID()
        var created: [UUID] = []
        func menu(_ host: UUID) -> WorkspaceListNewWorkspaceMenu {
            WorkspaceListNewWorkspaceMenu(
                value: WorkspaceListNewWorkspaceMenuValue(
                    canCreate: true,
                    canCreateGroup: false,
                    sshKinds: options,
                    sshTargetHostID: host
                ),
                actions: WorkspaceListNewWorkspaceMenuActions(
                    createWorkspace: {},
                    createWorkspaceGroup: nil,
                    createSSHWorkspace: { _ in created.append(host) }
                )
            )
        }
        #expect(menu(first) == menu(first))
        #expect(menu(first) != menu(second))
        menu(second).actions.createSSHWorkspace?(.shell)
        #expect(created == [second])
    }

    @Test func groupedLayoutReachesThePickerAndNamesItsActions() {
        let row = MobileSSHTabRow(id: "cmux-ssh-x~tmux:work/%1", title: "Pane 1", paneLabel: nil, startsPane: false)
        let layout = MobileSSHTabLayout(
            kind: .tmux,
            sections: [MobileSSHTabSection(id: "0", title: "0: zsh", rows: [row], actions: [.splitRight, .splitDown])]
        )
        let terminal = MobileTerminalPreview(id: .init(rawValue: row.id), name: "0:zsh · pane 1")
        let value = TerminalPickerMenuValue(
            liveTerminals: [terminal],
            selectedID: terminal.id,
            canCreateWorkspace: true,
            hasActiveBrowser: false,
            sshTabLayout: layout
        )
        #expect(value.sshTabLayout == layout)
        #expect(value.checkedRowID == TerminalPickerMenuRow.ID.terminal(terminal.id))
        #expect(value.selectedName == "0:zsh · pane 1")
        #expect(layout.newTerminalTitle == "New Window")
        // The splits carry the cmux macOS action names, one per direction.
        #expect(layout.sections.first?.actions.map(\.title) == ["Split Right", "Split Down"])

        var tui = layout
        tui.kind = MobileSSHWorkspaceKind.cmuxTUI
        #expect(tui.newTerminalTitle == "New Screen")
        #expect(MobileSSHSectionAction.allCases.map(\.title) == ["New Tab", "Split Right", "Split Down"])
        #expect(MobileSSHSectionAction.splitRight.accessibilityIdentifier(section: "3") == "MobileSSHSectionAction-splitRight-3")
        #expect(MobileSSHSectionAction.splitDown.accessibilityIdentifier(section: "3") == "MobileSSHSectionAction-splitDown-3")
        // A different layout is available on the next menu opening.
        let flat = TerminalPickerMenuValue(
            liveTerminals: [terminal],
            selectedID: terminal.id,
            canCreateWorkspace: true,
            hasActiveBrowser: false
        )
        #expect(flat != value)
    }
}
