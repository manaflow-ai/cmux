#if DEBUG
/// DEBUG ONLY: the no-Home prototype's data, the same in every variant: one Chief with three subagents, two other
/// Chiefs, a group chat, a DM, and four workspaces with their agent chats.
struct ChiefNoHomeFixture {
    let chief = ChiefNoHomeThread(id: "chief", kind: .chief, title: "Chief", detail: "Landing the sidebar redesign", status: .working)
    let subagents: [ChiefNoHomeThread] = [
        .init(id: "a1307", kind: .subagent, title: "a1307 · Chief replaces Home", detail: "Fleet green, 2 suites left", status: .working, workspace: "ws-sidebar"),
        .init(id: "a1315", kind: .subagent, title: "a1315 · Simplify the UI", detail: "Needs you: which cuts to keep", status: .needsYou, workspace: "ws-ui"),
        .init(id: "a1290", kind: .subagent, title: "a1290 · Fix login redirect", detail: "Landed 3f2a9c1", status: .done, workspace: "ws-login"),
    ]
    let chats: [ChiefNoHomeThread] = [
        .init(id: "design", kind: .otherChief, title: "Design Chief", detail: "Three icon sets are ready", unread: 2, minutesAgo: 4),
        .init(id: "team", kind: .group, title: "cmux team", detail: "Austin: nightly is out", unread: 5, minutesAgo: 12),
        .init(id: "david", kind: .direct, title: "David Beyer", detail: "threads should all be threads", unread: 1, minutesAgo: 31),
        .init(id: "ops", kind: .otherChief, title: "Ops Chief", detail: "Fleet queue is clear", minutesAgo: 95),
    ]
    let agents: [ChiefNoHomeThread] = [
        .init(id: "claude-1", kind: .agent, title: "Claude · sidebar rows", detail: "Editing SidebarItemInfo.swift", status: .working, workspace: "ws-sidebar"),
        .init(id: "codex-1", kind: .agent, title: "Codex · review", detail: "2 findings", status: .needsYou, workspace: "ws-ui"),
    ]
    let workspaces: [ChiefNoHomeWorkspace] = [
        .init(id: "ws-sidebar", name: "Chief in the sidebar", branch: "feat-cmux-next", lines: [
            "$ cmux-ci wait 7e898c18b6c1", "  ChiefReplacesHomeTests ............ passed (5)",
            "  PinnedRowShownTabIconTests ........ passed (3)", "  ShowChiefAlwaysShowsTheChiefTests . passed (3)", "$ █"]),
        .init(id: "ws-ui", name: "Simplify the UI", branch: "ui-cuts", lines: ["$ git diff --stat", " 41 files changed, 312 insertions(+), 1890 deletions(-)", "$ █"]),
        .init(id: "ws-login", name: "Fix login redirect", branch: "fix-login", lines: ["$ bun test auth", " 18 pass, 0 fail", "$ █"]),
        .init(id: "ws-gates", name: "Speed up parity gates", branch: "gates", lines: ["$ █"]),
    ]

    /// The Chief's chat, oldest first: who wrote and what.
    let messages: [(author: String, text: String)] = [
        ("Lawrence", "Where are we on the sidebar redesign?"),
        ("Chief", "a1307 has the Chief as the top row and its chat full width; fleet is green on 3 of 5 runs. a1315 needs you: which UI cuts to keep."),
        ("Lawrence", "Show me the cuts."),
        ("Chief", "a1315 sent 6 cuts. I opened its chat beside this one. Default picked: keep 4, drop the two that hide shortcuts."),
    ]

    /// Agent chats and subagents that work in `workspace`.
    func threads(in workspace: String) -> [ChiefNoHomeThread] {
        (agents + subagents).filter { $0.workspace == workspace }
    }
}
#endif
