#if DEBUG
import Foundation

/// DEBUG ONLY: one agent of the Agent Messages Playground's run (user 2026-11-03, msg 19960): what its pill
/// and its chat show. Made-up agents and work in the Chief's real wording; the labels are DEV-only English.
struct HomeAgentPlaygroundAgent: Sendable, Equatable {
    /// One message in the agent's chat besides the task: from the agent (`sender` nil), or a message the
    /// human (`You`) or the Chief (`Chief`) sent it through the shared composer.
    struct Message: Sendable, Equatable {
        var sender: String?
        var text: String
    }

    let peer: String
    /// The task's title line (the pill's text).
    let title: String
    /// `told` (working), `reported` or `stopped`.
    let state: String
    /// The task the Chief sent (its first line is the title).
    let task: String
    /// "Worked for 5m 35s" and the like.
    let workedFor: String
    /// What the agent did, one step a line (behind "Worked for ›").
    let steps: [String]
    var messages: [Message]

    /// The status words under the title.
    var status: String {
        switch state {
        case "reported": "Reported"
        case "stopped": "Stopped without a report"
        default: "Working"
        }
    }

    static let all: [HomeAgentPlaygroundAgent] = [
        HomeAgentPlaygroundAgent(
            peer: "a959", title: "Sidebar alignment fix", state: "reported",
            task: """
            Sidebar alignment fix

            Fix the sidebar alignment: the header and the New Workspace row share one left edge. Measure both in \
            the real app at 100% and 200%, light and dark. Root cause first, then a failing test, then the fix. \
            cmux-ci urgent, rebase, plain push to feat-cmux-next. Report OLD..NEW with before and after shots.
            """,
            workedFor: "Worked for 5m 35s",
            steps: ["Read SidebarHeaderView.swift and NewWorkspaceRow.swift", "Measured both rows: 16 pt and 12 pt",
                    "Added a failing layout test (red on the fleet)", "Fixed the header inset; test green",
                    "Pushed 41f05ff..631d310 to feat-cmux-next"],
            messages: [
                Message(text: "Root cause: the header used the window's safe-area inset (16 pt); the row used the sidebar's 12 pt padding."),
                Message(text: "Done: both rows now start at 12 pt. Landed 41f05ff..631d310 on feat-cmux-next."),
            ]),
        HomeAgentPlaygroundAgent(
            peer: "a931", title: "Nightly appcast rebuild", state: "told",
            task: """
            Nightly appcast rebuild

            Rebuild the nightly appcast on an owned Mac mini (never Blacksmith), check the feed and the installed \
            NIGHTLY are on the same build, then plain push.
            """,
            workedFor: "Working for 2m 10s",
            steps: ["Queued the nightly job on cmux-mini-3", "Waiting for the notarization step"],
            messages: [Message(sender: "Chief", text: "The fleet queue is clear now: bump your job with cmux-ci urgent.")]),
        HomeAgentPlaygroundAgent(
            peer: "a940", title: "First-click button audit", state: "told",
            task: """
            First-click button audit

            Audit every button for first-click response, active and inactive window. Fix the causes and add a CI guard.
            """,
            workedFor: "Working for 48s",
            steps: ["Listed 212 buttons in 38 views"],
            messages: []),
        HomeAgentPlaygroundAgent(
            peer: "a933", title: "a933", state: "stopped", task: "Chat switch scroll\n\nThe chat must show at the bottom on its first frame.",
            workedFor: "Stopped after 1m 12s", steps: ["Its session is Disconnected"],
            messages: [Message(text: "(stopped without a report: its session is Disconnected)")]),
        HomeAgentPlaygroundAgent(
            peer: "a936", title: "a936", state: "stopped", task: "Image table rendering\n\nRender images in table cells as thumbnails.",
            workedFor: "Stopped after 3m 02s", steps: ["Its session is Disconnected"],
            messages: [Message(text: "(stopped without a report: its session is Disconnected)")]),
    ]

    /// The agent `peer` of the run (a bare one for an id not in it).
    static func named(_ peer: String) -> HomeAgentPlaygroundAgent {
        all.first { $0.peer == peer }
            ?? HomeAgentPlaygroundAgent(peer: peer, title: peer, state: "told", task: "", workedFor: "", steps: [], messages: [])
    }

    /// The playground run's agent messages, in the Chief's order: the three tasks, a959's report, the two stops.
    static var run: [(peer: String, outgoing: Bool, text: String)] {
        let told = all.filter { $0.state != "stopped" }.map { (peer: $0.peer, outgoing: true, text: $0.task) }
        let report = all.filter { $0.state == "reported" }.compactMap { agent in
            agent.messages.last.map { (peer: agent.peer, outgoing: false, text: $0.text) }
        }
        let stops = all.filter { $0.state == "stopped" }.map { (peer: $0.peer, outgoing: false, text: $0.messages.first?.text ?? "") }
        return told + report + stops
    }
}
#endif
