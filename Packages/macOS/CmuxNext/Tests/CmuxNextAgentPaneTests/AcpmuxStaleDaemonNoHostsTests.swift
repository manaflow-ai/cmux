import Testing
@testable import CmuxNextAgentPane

/// A stale acpmux daemon without agent hosts (a build from before them, or `ACPMUX_AGENT_HOSTS=0`)
/// that keeps its chats on disk is handed off to the bundled build like one with agent hosts, also
/// mid-turn with no wait for idle: its agents end, and the new daemon reads the chats back and
/// resumes each on its next prompt (acpmux `tests/durable_agents.rs`, `queue_restore.rs` pin that
/// with `ACPMUX_AGENT_HOSTS=0`). Only a memory store without agent hosts keeps running.
@Suite struct AcpmuxStaleDaemonNoHostsTests {
    @Test func aStaleDaemonWithoutAgentHostsThatKeepsItsChatsOnDiskRestarts() {
        #expect(AcpmuxVersionHandoff.decide("old", "new", false, chatsOnDisk: true) == .restart)
        #expect(AcpmuxVersionHandoff.decide("old", "new", false, chatsOnDisk: true, replaced: true) == .restart)
        #expect(AcpmuxVersionHandoff.decide("old", "new", true, chatsOnDisk: true) == .restart)
        #expect(AcpmuxVersionHandoff.decide("old", "new", true, chatsOnDisk: false) == .restart)
    }

    @Test func aMemoryStoreWithoutAgentHostsKeepsRunning() {
        #expect(AcpmuxVersionHandoff.decide("old", "new", false, chatsOnDisk: false) != .restart)
        #expect(AcpmuxVersionHandoff.decide("old", "new", false, chatsOnDisk: false, replaced: true) != .restart)
        #expect(!AcpmuxVersionHandoff.keepsItsChats(agentHosts: false, chatsOnDisk: false))
        #expect(AcpmuxVersionHandoff.keepsItsChats(agentHosts: false, chatsOnDisk: true))
    }

    @Test func theSameOrAnUnknownBuildStillKeepsRunning() {
        #expect(AcpmuxVersionHandoff.decide("same", "same", false, chatsOnDisk: true) == .keep("same build"))
        #expect(AcpmuxVersionHandoff.decide(nil, "new", false, chatsOnDisk: true) == .keep("running build unknown"))
        #expect(AcpmuxVersionHandoff.decide("old", nil, false, chatsOnDisk: true) == .keep("bundled build unknown"))
    }

    /// `_acpmux/status` `store.mode`: `local` keeps the chats on disk; `memory`, or a status that
    /// does not say, does not.
    @Test func whereTheChatsAreKeptIsReadFromStatus() {
        #expect(AcpmuxStatus(["store": ["mode": "local", "segmentBytes": 4_194_304]]).chatsOnDisk)
        #expect(!AcpmuxStatus(["store": ["mode": "memory", "segmentBytes": 4_194_304]]).chatsOnDisk)
        #expect(!AcpmuxStatus(["build": "abc"]).chatsOnDisk)
        #expect(!AcpmuxStatus(["store": "local"]).chatsOnDisk)
    }
}
