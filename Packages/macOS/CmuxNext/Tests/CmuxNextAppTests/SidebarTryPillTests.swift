@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import AppKit
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Aziz, 2026-11-09: "since all workspaces are units of tasks, make it so that whenever a workspace
/// agent finished its task, theres a direct way for me to try out and verify its work in addition
/// to the artifact." acpmux serves a chat's `tryIt` (its newest wrap-up's `try`, `verify`, `report`);
/// the session tree feed turns it into the workspace row's Try pill, which the row draws and a click
/// opens.
@MainActor @Suite struct SidebarTryPillTests {
    private static let localHost = "install:mac"

    private static func lane(_ summary: [String: Any]) -> AgentActivityLane {
        var full: [String: Any] = ["sessionId": "s1", "name": "s1", "lane": ["state": "idle"]]
        full.merge(summary) { _, new in new }
        return AgentActivityLane.of(summary: full)!
    }

    @Test func aSummarysTryItReachesTheLaneAndRefusesAnUnsafeTarget() {
        let lane = Self.lane(["tryIt": ["label": "Open try-agent-work build", "url": "http://127.0.0.1:17320/try-agent-work",
                                        "verify": ["Finish a task: its row shows Try."], "report": "/tmp/r.html", "at": 5000]])
        #expect(lane.tryIt?.url == "http://127.0.0.1:17320/try-agent-work")
        #expect(lane.tryIt?.verify == ["Finish a task: its row shows Try."])
        #expect(lane.tryIt?.at == Date(timeIntervalSince1970: 5))
        #expect(Self.lane(["tryIt": ["url": "javascript:alert(1)"]]).tryIt == nil)
        #expect(Self.lane(["tryIt": ["command": "ls\nrm -rf ~"]]).tryIt == nil)
        // Review of #40089: a carriage return, Ctrl-U, an escape or a bidi override could run a line
        // other than the one the tooltip shows.
        for hidden in ["echo hi\rrm -rf ~", "rm -rf ~\u{15}echo safe", "ls \u{1b}[2K", "ls \u{202e}fdp.txt"] {
            #expect(Self.lane(["tryIt": ["command": hidden]]).tryIt == nil, "\(hidden.debugDescription)")
        }
        #expect(Self.lane([:]).tryIt == nil)
    }

    @Test func eachWorkspaceGetsItsNewestChatsTryAndOnlyFromThisMac() {
        let older = AgentLaneTry(label: nil, url: nil, command: "make demo", verify: [], report: nil, at: Date(timeIntervalSince1970: 1))
        let newer = AgentLaneTry(label: "Open build", url: "http://127.0.0.1:17320/t", command: nil, verify: ["Look."], report: nil,
                                 at: Date(timeIntervalSince1970: 2))
        let stepsOnly = AgentLaneTry(label: nil, url: nil, command: nil, verify: ["Look."], report: "/tmp/r.html", at: .distantFuture)
        func links(_ found: AgentLaneTry?) -> AgentLaneLinks {
            var lane = AgentLaneLinks(AgentActivityLane(id: "x", name: "x", title: "x", peer: nil, parent: nil, state: .idle,
                                                        since: nil, error: nil))
            lane.tryIt = found
            return lane
        }
        let chats: [(WorkspaceID, [AgentSessionRef])] = [
            (WorkspaceID("ws-a"), [AgentSessionRef(host: Self.localHost, session: "a1"), AgentSessionRef(host: Self.localHost, session: "a2"),
                                   AgentSessionRef(host: Self.localHost, session: "a3")]),
            (WorkspaceID("ws-remote"), [AgentSessionRef(host: "registry:vm", session: "a1")]),
            (WorkspaceID("ws-none"), [AgentSessionRef(host: Self.localHost, session: "n1")]),
        ]
        var mirrored = links(newer)
        mirrored.peer = "studio"
        let tries = SidebarSessionTreeFeed.tries(chats + [(WorkspaceID("ws-peer"), [AgentSessionRef(host: Self.localHost, session: "p1")])],
                                                 links: ["a1": links(older), "a2": links(newer), "a3": links(stepsOnly), "n1": links(nil),
                                                         "p1": mirrored],
                                                 localHost: Self.localHost)
        // Review of #40089: a peer's mirrored chat is that machine's work, never a pill here.
        #expect(tries == [WorkspaceID("ws-a"): SidebarTry(label: "Open build", url: "http://127.0.0.1:17320/t", verify: ["Look."])])
    }

    @Test func theRowDrawsThePillOnlyWithAnOpenerAndAClickOpensItsWorkspacesTry() {
        let pill = SidebarTryPillView()
        let found = SidebarTry(label: "Open build", url: "http://127.0.0.1:17320/t", verify: ["Look."])
        let saved = SidebarSessionTree.shared.onTry
        defer { SidebarSessionTree.shared.onTry = saved }
        SidebarSessionTree.shared.onTry = nil
        pill.configure(found, workspace: WorkspaceID("ws-a"))
        #expect(pill.isHidden)
        var opened: [(WorkspaceID, SidebarTry)] = []
        SidebarSessionTree.shared.onTry = { opened.append(($0, $1)) }
        pill.configure(found, workspace: WorkspaceID("ws-a"))
        #expect(!pill.isHidden)
        #expect(SidebarTryPillView.toolTip(found) == "Open build\nhttp://127.0.0.1:17320/t\n☐ Look.")
        #expect(pill.accessibilityPerformPress())
        #expect(opened.map(\.0) == [WorkspaceID("ws-a")])
        pill.configure(SidebarTry(label: "Only steps", verify: ["Look."]), workspace: WorkspaceID("ws-a"))
        #expect(pill.isHidden)
    }

    /// Review of #40089: the row hit-tests only its listed controls, so a pill missing from them drew
    /// its hover and never got the click; the list selected the row instead.
    @Test func aClickOnTheRowsPillReachesThePill() {
        let saved = SidebarSessionTree.shared.onTry
        defer { SidebarSessionTree.shared.onTry = saved }
        SidebarSessionTree.shared.onTry = { _, _ in }
        let row = WorkspaceRowView(key: .workspace(WorkspaceID("ws-a")))
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        row.configureTry(SidebarTry(label: "Open build", url: "http://127.0.0.1:17320/t"), workspace: WorkspaceID("ws-a"))
        row.tryPill.frame = NSRect(x: 220, y: 10, width: 40, height: 20)
        #expect(row.hitTest(NSPoint(x: 230, y: 20)) === row.tryPill)
        row.configureTry(nil, workspace: WorkspaceID("ws-a"))
        #expect(row.hitTest(NSPoint(x: 230, y: 20)) == nil)
    }
}
