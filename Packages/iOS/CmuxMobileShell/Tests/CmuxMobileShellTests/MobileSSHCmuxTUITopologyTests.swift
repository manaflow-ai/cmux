@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

/// cmux-tui rows follow changes made elsewhere (a laptop adds a screen or
/// tab), and each screen offers New Tab, Split Right, and Split Down
/// (PRD D32).
@Suite struct MobileSSHCmuxTUITopologyTests {
    /// A burst of tree changes asks for one relist; a change during that
    /// listing asks again once it started.
    @Test func treeChangesCoalesceToOneRelistPerListing() {
        var gate = MobileSSHCmuxTUITopologyGate()
        var asked: [Bool] = []
        asked.append(gate.admit(.treeChanged))
        asked.append(gate.admit(.treeChanged))
        asked.append(gate.admit(.surfaceExited(surface: 3)))
        gate.listed()
        asked.append(gate.admit(.surfaceExited(surface: 3)))
        #expect(asked == [true, false, false, true])
    }

    /// Titles, sizes, and bells never change rows; an exit, a closed last
    /// workspace, a lost subscription, or a gone owner does.
    @Test func onlyTopologyEventsAskForARelist() {
        let relists: [CmuxTUIControlEvent] = [.treeChanged, .surfaceExited(surface: 1), .empty, .overflow, .daemonShutdown, .disconnected]
        let ignored: [CmuxTUIControlEvent] = [.titleChanged(surface: 1, title: "vim"), .surfaceResized(surface: 1, cols: 80, rows: 24), .bell(surface: 1)]
        #expect(relists.allSatisfy(MobileSSHCmuxTUITopologyGate.changesTopology))
        #expect(!ignored.contains(where: MobileSSHCmuxTUITopologyGate.changesTopology))
        var gate = MobileSSHCmuxTUITopologyGate()
        let asked = ignored.map { gate.admit($0) }
        #expect(asked == [false, false, false])
    }

    /// A cmux-tui screen with a pane offers New Tab, then Split Right and
    /// Split Down; tmux windows offer both splits; shells and paneless
    /// screens offer nothing.
    @Test @MainActor func sectionActionsPerKind() throws {
        #expect(MobileSSHComputers.sectionActions(kind: .cmuxTUI, targetPane: 6) == [.newTab, .splitRight, .splitDown])
        #expect(MobileSSHComputers.sectionActions(kind: .cmuxTUI, targetPane: nil) == [])
        #expect(MobileSSHComputers.sectionActions(kind: .tmux, targetPane: nil) == [.splitRight, .splitDown])
        #expect(MobileSSHComputers.sectionActions(kind: .shell, targetPane: nil) == [])

        let tui = CmuxTUIWorkspace(
            id: 1,
            key: "k1",
            name: "api",
            terminals: [CmuxTUITerminal(surface: 1, pane: 10, screen: 100, resourceID: "term_a", title: "zsh")],
            screens: [CmuxTUIScreen(id: 100, name: nil, activePane: 10, panes: [CmuxTUIPane(id: 10)])]
        )
        let workspace = MobileSSHHostProviders.rekey(MobileSSHCmuxTUIProvider.workspace(tui), kind: .cmuxTUI, session: "main")
        let layout = MobileSSHComputers.tabLayout(workspace, hostID: UUID())
        #expect(try #require(layout.sections.first).actions == [.newTab, .splitRight, .splitDown])
    }

    /// Each switcher split names its direction, and directions map onto the
    /// wire commands: right is side by side (tmux `-h`), down is stacked
    /// (tmux `-v`) — tmux names the flag by the divider's motion, so the
    /// mapping is deliberately cross-axis.
    @Test func splitActionsCarryTheirDirection() {
        #expect(MobileSSHSectionAction.splitRight.splitDirection == .right)
        #expect(MobileSSHSectionAction.splitDown.splitDirection == .down)
        #expect(MobileSSHSectionAction.newTab.splitDirection == nil)
        #expect(MobileSSHTmuxProvider.splitFlag(.right) == "-h")
        #expect(MobileSSHTmuxProvider.splitFlag(.down) == "-v")
    }
}
