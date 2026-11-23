import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

/// Sample subagents for captures (`sidebar.subagents.fixture`, Debug, off): every other workspace row gets a chat
/// with three subagents (one finished, two running) and one row gets six, so a capture slot, which runs no
/// agents, shows the nested rows, "N more" and the stacked line without real sessions.
@MainActor
enum SidebarSubagentFixture {
    static let titles = ["Checkout: label the form fields", "Images: lazy-load below the fold",
                         "Cart: add width and height to thumbnails", "Measure the layout shift", "Review the diff",
                         "Gallery shots", "Run the test suite", "Watch CI"]

    /// `workspace`'s sample subagents; a name always gets the same ones, so a capture's rows do too. Nil for half the rows.
    static func subagents(_ workspace: WorkspaceModel) -> SidebarSubagents? {
        guard let tab = workspace.screens.flatMap(\.panes).flatMap(\.tabs).first else { return nil }
        let pick = workspace.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 4
        guard pick != 0 else { return nil }
        let count = pick == 3 ? 7 : 3
        let states: [SidebarSubagent.State] = [.done, .running, .running, .failed, .done, .running, .done]
        let items = (0..<count).map { index in
            SidebarSubagent(id: "fixture-\(workspace.id)-\(index)", title: titles[index % titles.count],
                            state: states[index % states.count], parent: index == 3 ? "fixture-\(workspace.id)-1" : nil,
                            tab: TabID(tab.id))
        }
        return SidebarSubagents(items: items, total: count == 7 ? 9 : 3, running: items.filter { $0.state == .running }.count,
                                chat: TabID(tab.id))
    }
}
