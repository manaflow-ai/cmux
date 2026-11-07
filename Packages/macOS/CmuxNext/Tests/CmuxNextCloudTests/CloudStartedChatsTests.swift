import CmuxNextCloud
import Foundation
import Testing

@MainActor
struct CloudStartedChatsTests {
    @Test func aCopyWaitsForItsOwnSessionAcrossARelaunch() throws {
        let suite = "CloudStartedChatsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CloudMovedChats()
        first.defaults = { defaults }
        let copy = CloudMovedChats.Entry(machineID: "vm-start", host: "registry:start", session: "", harness: "claude",
                                        localRoot: "/local/project", localChat: "/local/project/web",
                                        remoteFolder: "/work/copy/project", remoteChat: "/work/copy/project/web")
        first.copied(copy)
        #expect(first.all().isEmpty, "a tab with no session appeared in access triage")
        let relaunched = CloudMovedChats()
        relaunched.defaults = { defaults }
        #expect(!relaunched.started(host: "registry:other", session: "chat", remoteChat: copy.remoteChat, harness: nil))
        #expect(!relaunched.started(host: copy.host, session: "chat", remoteChat: "/work/other", harness: nil))
        #expect(!relaunched.started(host: copy.host, session: "home-chat", remoteChat: nil, harness: nil))
        #expect(relaunched.started(host: copy.host, session: "chat", remoteChat: copy.remoteChat, harness: "codex"))
        var expected = copy
        expected.session = "chat"
        expected.harness = "codex"
        #expect(relaunched.entry(host: copy.host, session: "chat") == expected)
        #expect(!relaunched.started(host: copy.host, session: "another-chat", remoteChat: copy.remoteChat, harness: nil))
        #expect(first.all() == [expected], "the committed mapping did not persist")
    }

    @Test func replayingACopyDoesNotOverwriteACommittedBringBack() throws {
        let ledger = CloudMovedChats()
        let copy = CloudMovedChats.Entry(machineID: "vm-start", host: "registry:start", session: "", localRoot: "/local",
                                        localChat: "/local", remoteFolder: "/remote", remoteChat: "/remote")
        ledger.copied(copy)
        #expect(ledger.started(host: copy.host, session: "chat", remoteChat: copy.remoteChat, harness: nil))
        var committed = try #require(ledger.entry(host: copy.host, session: "chat"))
        committed.broughtBack = .init(session: "local-chat", key: "transfer")
        ledger.record(committed)
        ledger.copied(copy)
        #expect(ledger.started(host: copy.host, session: "chat", remoteChat: copy.remoteChat, harness: nil))
        #expect(ledger.entry(host: copy.host, session: "chat") == committed)
    }
}
