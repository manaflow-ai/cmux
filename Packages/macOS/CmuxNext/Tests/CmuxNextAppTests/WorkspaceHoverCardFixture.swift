import Foundation
@testable import CmuxNextDesign
@testable import CmuxNextSidebar

/// Lawrence msg 19245's workspace ("Chief TUI + fast iteration", a screenshot of its hover card): 13 tabs
/// mixing terminals (a cwd, a git branch, a running agent with a spinner, one unread), browser tabs (a host,
/// two about:blank) and agent chats. Shared by `WorkspaceHoverCardGridTests` and the variants gallery.
@MainActor enum WorkspaceHoverCardFixture {
    static let title = "Chief TUI + fast iteration"
    /// The card's clock: every tab's last activity is an offset from it.
    static let now = Date(timeIntervalSince1970: 1_793_000_000)

    static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    static var tabs: [SidebarTab] {
        [
            SidebarTab(id: TabID("blank-1"), title: "about:blank", kind: .browser),
            SidebarTab(id: TabID("scratch"), title: "Chief TUI (scratch)", kind: .terminal, folder: "~"),
            SidebarTab(id: TabID("evals"), title: "Chief evals: use cases", kind: .agentChat, brand: "claude",
                       folder: "~/fun/cmuxterm-hq", state: .working),
            SidebarTab(id: TabID("blank-2"), title: "about:blank", kind: .browser),
            SidebarTab(id: TabID("tui"), title: "cmux-tui watch", kind: .terminal, folder: "~/fun/cmux", state: .busy),
            SidebarTab(id: TabID("claude"), title: "Claude Code", kind: .terminal, brand: "claude",
                       folder: "~/fun/cmux/Packages/macOS", state: .working),
            SidebarTab(id: TabID("codex"), title: "Codex: sidebar audit", kind: .agentChat, brand: "codex",
                       folder: "~/fun/cmux", state: .waiting),
            SidebarTab(id: TabID("pr"), title: "Update card cancel · Pull Request #29653", kind: .browser),
            SidebarTab(id: TabID("docs"), title: "cmux docs: hover cards", kind: .browser, isUnread: true),
            SidebarTab(id: TabID("hq"), title: "zsh", kind: .terminal, isUnread: true, folder: "~/fun/cmuxterm-hq", state: .error),
            SidebarTab(id: TabID("local"), title: "localhost:3000", kind: .browser),
            SidebarTab(id: TabID("tests"), title: "swift test", kind: .terminal, folder: "~/fun/cmux/Packages", state: .success),
            SidebarTab(id: TabID("chief"), title: "Chief", kind: .agentChat, isUnread: true),
        ]
    }

    static var content: WorkspaceHoverCardContent {
        WorkspaceHoverCardContent(title: title, icon: .terminal, age: "3m",
                                  facts: [.init(icon: .folder, text: "~/fun/cmux", kind: "folder")])
    }
}
