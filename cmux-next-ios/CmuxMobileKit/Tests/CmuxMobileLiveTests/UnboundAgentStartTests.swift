#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// A new agent tab with no chat yet starts its chat from the phone (Leo, 2026-11-18: "you should be
/// able to just start the chat right there. Why is this dialogue showing?"). The tab shows no
/// "hasn't started" notice; its first send starts the chat (UnboundChatFirstMessageTests), and
/// with no link to its Mac the draft comes back naming the Mac.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct UnboundAgentStartTests {
    static let summary = AgentSessionSummary(id: "t9", name: "New chat", harness: "claude", agentName: "Claude", cwd: "/tmp/w",
                                             workspaceTitle: "w", macName: "mini", macID: "mac1", accountID: "acct")

    private func prompt(_ text: String) -> AgentClientIntent {
        .prompt(text: text, attachments: [], steer: false, promptID: "p1", resend: false)
    }

    /// Collects what the source yields until `count` events came.
    private func take(_ count: Int, from source: UnboundAgentSource) -> Task<[AgentSessionEvent], Never> {
        let stream = source.events()
        return Task {
            var got: [AgentSessionEvent] = []
            for await event in stream {
                got.append(event)
                if got.count == count { break }
            }
            return got
        }
    }

    @Test func withNoLinkTheDraftComesBackNamingTheMac() async {
        let source = UnboundAgentSource(summary: Self.summary, start: nil)
        let events = take(1, from: source)
        source.send(prompt("hello"))
        let got = await events.value
        guard case .promptNotSent(let text, _, _, let reason) = got.first else { Issue.record("got \(got)"); return }
        #expect(text == "hello")
        #expect(reason == UnboundAgentSource.notConnected(mac: "mini"))
    }

    @Test func onlyThisMacsOwnTabsStartHere() {
        #expect(LiveWorkspaceCreationBackend.startsHere(host: nil))
        #expect(LiveWorkspaceCreationBackend.startsHere(host: ""))
        #expect(LiveWorkspaceCreationBackend.startsHere(host: "install:abc"))
        #expect(!LiveWorkspaceCreationBackend.startsHere(host: "ssh:box"))
    }
}
#endif
