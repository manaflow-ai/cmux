import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// An agent chat tab the user has not named reads as its chat, not "Agent" (dogfood run,
/// hq #1893): Home's Your agents listed every chat as "Agent". The app's turn-state watch
/// keeps each local chat's title as the page names it (sessionList.ts `sessionTitle`): the
/// name the user gave, else the agent's title, else the first prompt; a chat with none of
/// them, or on another Mac, stays "Agent".
@MainActor
@Suite(.serialized)
struct AgentChatTabTitleTests {
    static let host = "install:chat-title"

    static func chat(_ session: String, host: String = host) -> AgentSessionRef {
        AgentSessionRef(host: host, session: session, harness: "claude-sr")
    }

    @Test func anUntitledChatTabReadsAsItsChat() async throws {
        let acpmux = try TaggingAcpmux(
            sessions: ["titled": [:], "prompted": [:], "named": [:], "fresh": [:]],
            fields: [
                "titled": [
                    "harness": "claude-sr", "name": "claude-sr", "title": "Fix the flaky upload test",
                    "lastPrompt": "the upload test flakes",
                ],
                "prompted": ["harness": "claude-sr", "name": "claude-sr-2", "lastPrompt": "Tighten the retry comment"],
                "named": ["harness": "claude-sr", "name": "Release notes", "title": "Draft the notes"],
                "fresh": ["harness": "claude-sr", "name": "claude-sr-3"],
            ])
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: turns, deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
        feed.start(localHost: Self.host)
        // The watch's first page carries the titles; a chat's mute is known (false) before it lands.
        try await until { AgentChatTabTitle.untitled(Self.chat("titled"), turns: turns) != AgentPaneModel.tabTitle }

        #expect(AgentChatTabTitle.untitled(Self.chat("titled"), turns: turns) == "Fix the flaky upload test")
        #expect(AgentChatTabTitle.untitled(Self.chat("prompted"), turns: turns) == "Tighten the retry comment")
        #expect(AgentChatTabTitle.untitled(Self.chat("named"), turns: turns) == "Release notes")
        #expect(AgentChatTabTitle.untitled(Self.chat("fresh"), turns: turns) == AgentPaneModel.tabTitle)
        #expect(AgentChatTabTitle.untitled(Self.chat("titled", host: "install:other-mac"), turns: turns) == AgentPaneModel.tabTitle)
        withExtendedLifetime((acpmux, feed)) {}
    }

    /// Waits up to five seconds for `done`.
    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}
