import CmuxNextDesign
import Foundation

/// Single-machine demo: 12 workspaces, 5 of them in two groups, two with
/// live agent status. Used for visual checks of the default density.
public struct SidebarDemoMock {
    public init() {}
    public static func makeModel() -> SidebarModel {
        let model = SidebarModel(sections: makeSections(), activeWorkspaceID: WorkspaceID("demo-3"))
        return model
    }

    public static func makeSections() -> [SidebarSection] {
        func ws(
            _ n: Int, _ title: String, cwd: String, status: String? = nil, icon: WorkspaceIcon? = nil,
            unread: UnreadState = .none, activity: StatusIndicatorState = .idle
        ) -> SidebarWorkspace {
            SidebarWorkspace(
                id: WorkspaceID("demo-\(n)"), title: title, subtitle: cwd, status: status,
                icon: icon, unread: unread, activity: activity
            )
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws(1, "cmux", cwd: "~/fun/cmux", icon: .swatch(.purple))),
            .workspace(ws(2, "sidebar agent", cwd: "~", status: "Claude: editing SidebarView.swift", unread: .count(2), activity: .busy)),
            .workspace(ws(3, "tabs agent", cwd: "~", status: "Codex: waiting for approval", unread: .dot, activity: .waiting)),
            .workspace(ws(4, "notes", cwd: "~/notes")),
            .group(SidebarGroup(id: GroupID("demo-g1"), name: "cmux-next", color: .purple, workspaces: [
                ws(5, "daemon", cwd: "~/fun/cmux-tui"),
                ws(6, "terminal", cwd: "~/fun/cmux", activity: .busy),
                ws(7, "palette", cwd: "~/fun/cmux"),
            ])),
            .group(SidebarGroup(id: GroupID("demo-g2"), name: "web", color: .green, workspaces: [
                ws(8, "next dev", cwd: "~/fun/cmux/web", status: "Tests · 40%", activity: .busy(progress: 0.4)),
                ws(9, "drizzle", cwd: "~/fun/cmux/web/db", status: "Migration failed (exit 1)", unread: .count(1), activity: .error),
            ])),
            .workspace(ws(10, "ghostty", cwd: "~/fun/ghostty", status: "zig build done in 2m 14s", icon: .swatch(.orange), activity: .success)),
            .workspace(ws(11, "htop", cwd: "~")),
            .workspace(ws(12, "scratch", cwd: "/tmp")),
        ])]
    }
}
