// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation

extension AppStore {
    /// Sample data for previews, UI verification and first-run demos.
    public static func mock(now: Date = Date(), tabMemory: TabMemory = .standard) -> AppStore {
        let teams = [
            // Two Macs, one asleep: the Workspaces list's realistic mix.
            Team(id: "team-manaflow", name: "Manaflow", macs: [
                MacDevice(id: "mac-studio", name: "Aziz's Mac Studio", isOnline: true),
                MacDevice(id: "mbp", name: "MacBook Pro", isOnline: false, lastSeenAt: now.addingTimeInterval(-2 * 3600)),
            ]),
            Team(id: "personal-mock", name: "Personal", appearance: TeamAppearance(colorHex: "#30D158", emoji: "🌵"), macs: [
                MacDevice(id: "mbp-home", name: "Home MacBook", isOnline: false),
                // Two Macs that share a name (a reinstall, or two laptops):
                // the lists tag each with its id ending.
                MacDevice(id: "8c41e0d2-3f2a", name: "Aziz's MacBook Pro", isOnline: true),
                MacDevice(id: "5b97a6f1-91c7", name: "Aziz's MacBook Pro", isOnline: false, lastSeenAt: now.addingTimeInterval(-3 * 86400)),
            ]),
            Team(id: "team-fleet", name: "Build Fleet", macs: (1...8).map {
                MacDevice(id: "mini-\($0)", name: "mini \($0)", isOnline: $0 % 3 != 0)
            }),
        ]
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        // Needs you (2), working (2), done (1), idle, then the asleep MacBook Pro's.
        let workspaces = [
            Workspace(
                id: "ws-cmux", macID: "mac-studio", title: "cmux", directory: "~/Development/cmux", branch: "feat-cmux-next-ios",
                tabs: [
                    WorkspaceTab(id: "t-claude", kind: .agent, title: "Claude", subtitle: "Refactor transport layer", harness: "claude",
                                 agentStatus: .waiting),
                    WorkspaceTab(id: "t-zsh", kind: .terminal, title: "zsh", subtitle: "~/Development/cmux"),
                    WorkspaceTab(id: "t-docs", kind: .browser, title: "Swift docs", subtitle: "developer.apple.com",
                                 url: URL(string: "https://developer.apple.com/documentation/swiftui")),
                ],
                lastActivityAt: ago(1), needsAttention: true, hasUnread: true,
                colorHex: "#0A84FF", icon: "terminal"
            ),
            Workspace(
                id: "ws-web", macID: "mac-studio", title: "cmux.com", directory: "~/Development/web", branch: "main",
                tabs: [
                    WorkspaceTab(id: "t-codex", kind: .agent, title: "Codex", subtitle: "Fix pricing page layout", harness: "codex",
                                 agentStatus: .working),
                    WorkspaceTab(id: "t-dev", kind: .terminal, title: "bun dev", subtitle: "localhost:3000"),
                ],
                lastActivityAt: ago(3), isWorking: true, colorHex: "#BF5AF2", icon: "globe"
            ),
            Workspace(
                id: "ws-ios", macID: "mac-studio", title: "cmux-next-ios", directory: "~/Development/cmux/cmux-next-ios", branch: "feat-cmux-next-ios-wsdesign",
                tabs: [
                    WorkspaceTab(id: "t-ios-build", kind: .terminal, title: "xcodebuild", subtitle: "~/Development/cmux/cmux-next-ios"),
                    WorkspaceTab(id: "t-ios-claude", kind: .agent, title: "Claude", subtitle: "Redesign the workspaces list", harness: "claude",
                                 agentStatus: .working),
                ],
                lastActivityAt: ago(6), isWorking: true, colorHex: "#30D158", icon: "iphone", activeTabID: "t-ios-build"
            ),
            Workspace(
                id: "ws-infra", macID: "mac-studio", title: "fleet", directory: "~/fleet", branch: "mini-recovery",
                tabs: [
                    WorkspaceTab(id: "t-fleet-claude", kind: .agent, title: "Claude", subtitle: "Audit runner labels", harness: "claude"),
                    WorkspaceTab(id: "t-htop", kind: .terminal, title: "htop", subtitle: "TUI"),
                ],
                lastActivityAt: ago(12), hasUnread: true, colorHex: "#FF9F0A", icon: "server.rack"
            ),
            // The waiting agent is the second tab: a tap still lands on it.
            Workspace(
                id: "ws-ghostty", macID: "mac-studio", title: "ghostty", directory: "~/Development/ghostty", branch: "sync-upstream",
                tabs: [
                    WorkspaceTab(id: "t-gh-zsh", kind: .terminal, title: "zsh", subtitle: "~/Development/ghostty"),
                    WorkspaceTab(id: "t-gh-codex", kind: .agent, title: "Codex", subtitle: "Resolve merge conflicts", harness: "codex",
                                 agentStatus: .waiting),
                ],
                lastActivityAt: ago(25), needsAttention: true
            ),
            Workspace(
                id: "ws-design", macID: "mac-studio", title: "design system", directory: "~/Development/design", branch: "tokens-v2",
                tabs: [WorkspaceTab(id: "t-design", kind: .terminal, title: "zsh", subtitle: "~/Development/design")],
                lastActivityAt: ago(130)
            ),
            Workspace(
                id: "ws-blog", macID: "mac-studio", title: "blog", directory: "~/Development/blog", branch: "main",
                tabs: [WorkspaceTab(id: "t-blog", kind: .browser, title: "Preview", subtitle: "localhost:4321",
                                    url: URL(string: "http://localhost:4321"))],
                lastActivityAt: ago(26 * 60)
            ),
            Workspace(
                id: "ws-release", macID: "mac-studio", title: "release 0.64", directory: "~/Development/cmux", branch: "release/0.64",
                tabs: [WorkspaceTab(id: "t-release", kind: .terminal, title: "zsh", subtitle: "~/Development/cmux")],
                lastActivityAt: ago(3 * 24 * 60)
            ),
            Workspace(
                id: "ws-zed", macID: "mbp", title: "zed", directory: "~/Development/zed", branch: "cmux-fork",
                tabs: [
                    WorkspaceTab(id: "t-zed-claude", kind: .agent, title: "Claude", subtitle: "Port the tab strip", harness: "claude"),
                    WorkspaceTab(id: "t-zed-cargo", kind: .terminal, title: "cargo build", subtitle: "~/Development/zed"),
                ],
                lastActivityAt: ago(150)
            ),
            Workspace(
                id: "ws-notes", macID: "mbp", title: "notes", directory: "~/notes", branch: "main",
                tabs: [WorkspaceTab(id: "t-notes", kind: .terminal, title: "nvim", subtitle: "~/notes")],
                lastActivityAt: ago(5 * 60)
            ),
            Workspace(
                id: "ws-dotfiles", macID: "mbp", title: "dotfiles", directory: "~/dotfiles", branch: "main",
                tabs: [WorkspaceTab(id: "t-dotfiles", kind: .terminal, title: "nvim", subtitle: "~/dotfiles")],
                lastActivityAt: ago(4 * 24 * 60)
            ),
            // Personal's same-name Macs (3F2A online, 91C7 asleep): the
            // Workspaces list's tagged rows and folded group.
            Workspace(
                id: "ws-site", macID: "8c41e0d2-3f2a", title: "site", directory: "~/Development/site", branch: "main",
                tabs: [WorkspaceTab(id: "t-site", kind: .terminal, title: "zsh", subtitle: "~/Development/site")],
                lastActivityAt: ago(40)
            ),
            Workspace(
                id: "ws-photos", macID: "5b97a6f1-91c7", title: "photos", directory: "~/photos", branch: "main",
                tabs: [WorkspaceTab(id: "t-photos", kind: .terminal, title: "zsh", subtitle: "~/photos")],
                lastActivityAt: ago(3 * 24 * 60 + 10)
            ),
        ]
        let feed = [
            FeedEvent(
                id: "e1",
                kind: .question(QuestionPrompt(items: [
                    QuestionPrompt.Item(header: "Transport", question: "Which transport should be the default on cellular?", options: [
                        QuestionPrompt.Option(label: "WebRTC", detail: "Uses TURN when no direct path exists."),
                        QuestionPrompt.Option(label: "WireGuard", detail: "Falls back to the relay."),
                    ]),
                ])),
                workspaceID: "ws-cmux", tabID: "t-claude", agentName: "Claude", harness: "claude",
                markdown: "I finished the **link framing**. Before wiring the dialers I need one decision:\n\n- WebRTC is faster to connect\n- WireGuard keeps one tunnel for every service",
                quotedPrompt: "Make the transport layer switchable between WebRTC and WireGuard",
                createdAt: now.addingTimeInterval(-45)
            ),
            FeedEvent(
                id: "e2", kind: .agentResponse, workspaceID: "ws-web", tabID: "t-codex", agentName: "Codex", harness: "codex",
                markdown: "Fixed the pricing table overflow on small screens.\n\n```diff\n- grid-template-columns: repeat(3, 1fr);\n+ grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));\n```\n\nAll 14 tests pass.",
                quotedPrompt: "the pricing page breaks on iPhone SE",
                createdAt: now.addingTimeInterval(-600)
            ),
            FeedEvent(
                id: "e3", kind: .permission(options: ["Allow once", "Always allow", "Deny"]), workspaceID: "ws-cmux", tabID: "t-claude",
                agentName: "Claude", harness: "claude",
                markdown: "Run `cargo test -p cmux-mobile-link`?",
                quotedPrompt: "run the tests", createdAt: now.addingTimeInterval(-1200)
            ),
        ]
        return AppStore(teams: teams, activeTeamID: "team-manaflow", workspaces: workspaces.enumerated().map { Self.mockLinkIDs($1, index: $0) }, feed: feed,
                        tabMemory: tabMemory)
    }

    /// Mac-style public ids for the samples, so cmux links resolve in mock mode
    /// (CmuxLink): workspace `n` is `ws_` + n in 32 hex digits, its tab `m` is
    /// `tab_` + n·16+m, all of a workspace's tabs share pane `pane_` + n (the first
    /// selected), and an agent tab's harness session is `mock-<tab id>`.
    static func mockLinkIDs(_ workspace: Workspace, index: Int) -> Workspace {
        func id(_ prefix: String, _ number: Int) -> String { prefix + String(format: "%032x", number) }
        var workspace = workspace
        workspace.resourceID = id("ws_", index + 1)
        for position in workspace.tabs.indices {
            let tab = workspace.tabs[position]
            workspace.tabs[position].linkIDs = WorkspaceTab.LinkIDs(
                tab: id("tab_", (index + 1) * 16 + position), pane: id("pane_", index + 1), isPaneSelected: position == 0,
                harnessSession: tab.isAgent ? "mock-\(tab.id)" : nil)
        }
        return workspace
    }
}
#endif
