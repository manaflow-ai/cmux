import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// Rename Agent Session… sends acpmux `_acpmux/rename` for the focused chat: the session's own
/// name (`cmux agent ls`, `HOST/NAME`) changes, not only the tab's title. Each test runs the app's
/// turn-state watch and the rename against the stand-in acpmux of `AgentChatMuteTests`.
@MainActor
@Suite(.serialized)
struct AgentChatRenameTests {
    @Test func renameSendsAcpmuxRenameAndTheAskStartsFromTheCurrentName() async throws {
        let acpmux = try TaggingAcpmux(sessions: ["r1": [:]], fields: ["r1": ["title": "Old title"]])
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: turns)
        feed.start(localHost: AgentChatMuteTests.host)
        let renamer = AgentChatRename(environment: try AgentChatMuteTests.environment(acpmux), turns: turns)
        let chat = AgentChatMuteTests.chat("r1")
        try await until { renamer.isLocal(chat) && acpmux.watching }
        #expect(renamer.currentName(chat) == "Old title", "with no name yet the ask starts from the title")

        #expect(try await renamer.rename(chat, to: "release-notes"))
        #expect(acpmux.name("r1") == "release-notes", "acpmux holds the new session name")
        try await until { renamer.currentName(chat) == "release-notes" }
        #expect(renamer.currentName(chat) == "release-notes", "the next ask starts from the new name")
        withExtendedLifetime((acpmux, feed)) {}
    }

    @Test func anotherMacsChatIsNotRenamed() async throws {
        let acpmux = try TaggingAcpmux(sessions: ["r2": [:]], fields: ["r2": ["title": "Left alone"]])
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: acpmux.path, turns: turns)
        feed.start(localHost: AgentChatMuteTests.host)
        let renamer = AgentChatRename(environment: try AgentChatMuteTests.environment(acpmux), turns: turns)
        try await until { renamer.isLocal(AgentChatMuteTests.chat("r2")) }
        let elsewhere = AgentChatMuteTests.chat("r2", host: "install:other-mac")
        #expect(!renamer.isLocal(elsewhere))
        #expect(try await renamer.rename(elsewhere, to: "nope") == false)
        #expect(acpmux.name("r2") == nil)
        withExtendedLifetime((acpmux, feed)) {}
    }

    /// Waits up to five seconds for `done`.
    private func until(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}
