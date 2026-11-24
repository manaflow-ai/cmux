import Foundation

/// The App Review demo account's content: one online Mac with workspaces whose
/// terminals answer in the phone (the scripted shell) and whose browser tabs load
/// their pages on the phone. Compiled into every build, shipping ones included,
/// and used only for an account the server marks with Stack's read-only
/// `cmuxReviewDemoContent` metadata (`CMUXAuthUser.demonstrationContentEnabled`),
/// which no client can set. Nothing here dials or reads a real Mac.
extension AppStore {
    /// The demo Mac's id; its workspaces name it.
    public static let reviewDemoMacID = "review-demo-mac"
    /// The demo account's one space.
    public static let reviewDemoTeamID = "personal-review-demo"

    /// Replaces this store's teams, Macs and workspaces with the demo account's,
    /// loaded and settled (no live data is awaited).
    public func loadReviewDemo(now: Date = Date()) {
        let demo = Self.reviewDemoContent(now: now)
        teams = demo.teams
        activeTeamID = demo.activeTeamID
        workspaces = demo.workspaces
        tracksMacData = false
        teamDataState = .loaded
    }

    /// The demo account's teams and workspaces (see ``loadReviewDemo(now:)``).
    static func reviewDemoContent(now: Date) -> (teams: [Team], activeTeamID: String, workspaces: [Workspace]) {
        let mac = MacDevice(id: reviewDemoMacID, name: "MacBook Pro", isOnline: true)
        let team = Team(id: reviewDemoTeamID, name: "Personal", macs: [mac])
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let workspaces = [
            Workspace(
                id: "review-ws-web", macID: mac.id, title: "website", directory: "~/Developer/website", branch: "main",
                tabs: [
                    WorkspaceTab(id: "review-t-web-zsh", kind: .terminal, title: "zsh", subtitle: "~/Developer/website"),
                    WorkspaceTab(id: "review-t-web-site", kind: .browser, title: "cmux", subtitle: "cmux.com",
                                 url: URL(string: "https://cmux.com")),
                ],
                lastActivityAt: ago(2), hasUnread: true, colorHex: "#0A84FF", icon: "globe"
            ),
            Workspace(
                id: "review-ws-api", macID: mac.id, title: "api-server", directory: "~/Developer/api-server", branch: "feature/search",
                tabs: [
                    WorkspaceTab(id: "review-t-api-build", kind: .terminal, title: "cargo", subtitle: "~/Developer/api-server"),
                    WorkspaceTab(id: "review-t-api-docs", kind: .browser, title: "Swift docs", subtitle: "developer.apple.com",
                                 url: URL(string: "https://developer.apple.com/documentation/swift")),
                ],
                lastActivityAt: ago(9), colorHex: "#30D158", icon: "server.rack"
            ),
            Workspace(
                id: "review-ws-notes", macID: mac.id, title: "notes", directory: "~/notes", branch: "main",
                tabs: [WorkspaceTab(id: "review-t-notes", kind: .terminal, title: "zsh", subtitle: "~/notes")],
                lastActivityAt: ago(95), colorHex: "#FF9F0A", icon: "terminal"
            ),
        ]
        return ([team], team.id, workspaces)
    }
}
