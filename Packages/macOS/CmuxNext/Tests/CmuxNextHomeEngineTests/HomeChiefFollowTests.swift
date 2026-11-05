@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// "I ask you to teleport somewhere and it just works" (a963, 2026-11-03): Home follows the Chief
/// with no step from the person. The home's `state/moved.json` says where it went; Home shows that
/// Chief's conversation (a hosted Chief's main conversation, a reachable host's), shows This Mac's
/// again once the marker is gone, and says where it is when Home cannot reach it.
struct HomeChiefFollowTests {
    private let chiefs = [
        HomeChiefRecord(id: "agent_default", name: "Chief", isDefault: true, rev: 1, mainConversation: "conv_default"),
        HomeChiefRecord(id: "agent_moved", name: "Chief", isDefault: false, rev: 1, mainConversation: "conv_moved"),
        HomeChiefRecord(id: "agent_mini", name: "Chief (Mac mini)", isDefault: false, rev: 1, mainConversation: "conv_mini", placed: true),
    ]

    @Test func theMarkerNamesTheHostedChiefsAgent() {
        #expect(ChiefWhereabouts(movedTo: "cloud:https://api.cmux.dev/agent_moved") == ChiefWhereabouts(location: .cloud, cloudAgentID: "agent_moved"))
        #expect(ChiefWhereabouts(movedTo: "cloud:https://api.cmux.dev/v1/agent_moved").cloudAgentID == "agent_moved")
        #expect(ChiefWhereabouts(movedTo: "cloud").cloudAgentID == nil)
        #expect(ChiefWhereabouts(movedTo: "ssh:mini:/h") == ChiefWhereabouts(location: .host("mini"), cloudAgentID: nil))
        #expect(ChiefWhereabouts(movedTo: nil) == .thisMac)
    }

    @Test func onThisMacTheEngineRowDecides() {
        let follow = HomeChiefFollow(whereabouts: .thisMac, chiefs: chiefs, reachableHost: nil)
        #expect(follow.target == .unchanged)
        #expect(follow.conversation == nil)
        #expect(follow.prefersLocal(true) == true)
        #expect(follow.prefersLocal(false) == false)
    }

    @Test func movedToCloudHomeShowsThatHostedChief() {
        let follow = HomeChiefFollow(whereabouts: ChiefWhereabouts(movedTo: "cloud:https://api.cmux.dev/agent_moved"),
                                     chiefs: chiefs, reachableHost: nil)
        #expect(follow.target == .conversation("conv_moved"))
        #expect(follow.conversation == "conv_moved", "the moved Chief, not the account's default one")
        #expect(follow.prefersLocal(true) == false, "this Mac's Chief no longer answers, whatever the Engine row says")
    }

    @Test func movedToCloudBeforeItsRecordIsReadHomeLeavesThisMac() {
        let follow = HomeChiefFollow(whereabouts: ChiefWhereabouts(movedTo: "cloud:https://api.cmux.dev/agent_new"),
                                     chiefs: chiefs, reachableHost: nil)
        #expect(follow.target == .waiting)
        #expect(follow.conversation == nil)
        #expect(follow.prefersLocal(true) == false)
    }

    @Test func movedToAReachableHostHomeShowsThatHostsChief() {
        let follow = HomeChiefFollow(whereabouts: ChiefWhereabouts(movedTo: "ssh:lawrence@cmux-mini:~/.cmux/chief/default"),
                                     chiefs: chiefs, reachableHost: (host: "CMUX-MINI", conversation: "conv_mini"))
        #expect(follow.target == .conversation("conv_mini"))
        #expect(follow.prefersLocal(true) == false)
    }

    @Test func movedToAHostHomeCannotReachItSaysWhereTheChiefIs() {
        let follow = HomeChiefFollow(whereabouts: ChiefWhereabouts(movedTo: "ssh:gcp-linux-1:~/.cmux/chief/default"),
                                     chiefs: chiefs, reachableHost: (host: "cmux-mini", conversation: "conv_mini"))
        #expect(follow.target == .away("gcp-linux-1"))
        #expect(follow.conversation == nil)
        #expect(follow.prefersLocal(false) == true, "Home stays on this Mac's conversation, whose chip says where the Chief went")
    }
}

/// The moved marker is followed by a file watcher on the home's `state` folder, never by polling:
/// a move writing `moved.json`, and a rollback removing it, each wake the stream.
struct ChiefMovedMarkerWatcherTests {
    /// Whether `stream` yields within the deadline. A deadline, not a poll: the event arrives at
    /// once; the clock only bounds a failure.
    private func wakes(_ stream: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: .seconds(10))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test func aMoveAndARollbackEachWakeTheStream() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chief-follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("state"), withIntermediateDirectories: true)
        let watcher = ChiefMovedMarkerWatcher(home: home)
        let changes = watcher.changes()
        let marker = home.appendingPathComponent(ChiefLocationReader.movedFile)
        try Data(#"{"to": "cloud:https://api.cmux.dev/agent_moved", "at": "t", "checkpoint_sha256": ""}"#.utf8).write(to: marker)
        #expect(await wakes(changes), "a move wrote the marker")
        #expect(await ChiefLocationReader().whereabouts(home: home).cloudAgentID == "agent_moved")
        try FileManager.default.removeItem(at: marker)
        #expect(await wakes(changes), "a rollback removed it")
        #expect(await ChiefLocationReader().read(home: home) == .thisMac)
    }

    @Test func aHomeWithNoStateFolderYetIsFollowedOnceItHasOne() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chief-follow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let watcher = ChiefMovedMarkerWatcher(home: home)
        let changes = watcher.changes()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("state"), withIntermediateDirectories: true)
        #expect(await wakes(changes), "the state folder appeared")
        try Data(#"{"to": "ssh:mini:/h", "at": "t", "checkpoint_sha256": ""}"#.utf8)
            .write(to: home.appendingPathComponent(ChiefLocationReader.movedFile))
        #expect(await wakes(changes), "the marker in the new folder")
        #expect(await ChiefLocationReader().read(home: home) == .host("mini"))
    }
}
