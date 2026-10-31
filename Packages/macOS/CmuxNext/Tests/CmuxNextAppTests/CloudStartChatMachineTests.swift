@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// Which machine a `cloud.startChat` send runs on (Leo, 2026-10-30: "like the initial 0 to 1 chat
/// auto it sends to cloud"): this person's free machine, never a teammate's busy one or a lane-pool
/// VM, else a new one for chats; and a retry of the same send stays on its first try's machine
/// (#28845), so it never opens a second chat with the prompt elsewhere.
@Suite
@MainActor
struct CloudStartChatMachineTests {
    private typealias Candidate = CloudStartChat.Candidate
    private static let me = "user-leo", teammate = "user-austin"

    private static func machine(_ id: String, _ title: String, by creator: String? = me, status: CloudMachine.Status = .running,
                                pause: CloudMachine.PauseReason? = nil, connected: Bool = true, chats: Int? = 0) -> Candidate {
        Candidate(id: id, title: title, slug: nil, createdBy: creator, status: status, pauseReason: pause,
                  connected: connected, chats: connected ? chats : nil)
    }

    @Test func aTeammatesConnectedMachineIsNeverTakenAndNoneOfMineMakesANewOne() {
        // The old pick: the first connected team machine. On Leo's account that is someone's lane VM.
        let team = [Self.machine("vm-a", "austin-box", by: Self.teammate), Self.machine("vm-b", "Cloud Machine", by: Self.teammate)]
        #expect(CloudStartChat.pick(team, user: Self.me, used: []) == nil)
        #expect(CloudStartChat.pick(team, user: nil, used: []) == nil)
    }

    @Test func aBusyMachineOfMineIsPassedOverForAFreeOne() {
        let machines = [Self.machine("vm-busy", "work", chats: 3), Self.machine("vm-free", "spare", chats: 0)]
        #expect(CloudStartChat.pick(machines, user: Self.me, used: []) == "vm-free")
        // Only busy ones: a new machine.
        #expect(CloudStartChat.pick([Self.machine("vm-busy", "work", chats: 1)], user: Self.me, used: []) == nil)
    }

    @Test func aMachineMarkedForChatsIsTakenFirstEvenWithChatsOpen() {
        let machines = [Self.machine("vm-free", "spare"), Self.machine("vm-chats", "cloud-chats", chats: 4)]
        #expect(CloudStartChat.pick(machines, user: Self.me, used: []) == "vm-chats")
        #expect(CloudStartChat.isMarkedForChats("Cloud-Chats-2"))
        #expect(!CloudStartChat.isMarkedForChats("cloud-chats-x"))
        // A teammate's machine for chats is still theirs.
        #expect(CloudStartChat.pick([Self.machine("vm-c", "cloud-chats", by: Self.teammate)], user: Self.me, used: []) == nil)
    }

    @Test func laneShellVMsAreNeverPicked() {
        let lanes = [Self.machine("vm-1", "fs-lane-3"), Self.machine("vm-2", "lane-vm-1"), Self.machine("vm-3", "LANE-VM-12")]
        #expect(CloudStartChat.pick(lanes, user: Self.me, used: []) == nil)
        var slugged = Self.machine("vm-4", "Leo's box")
        slugged.slug = "fs-lane-7"
        #expect(CloudStartChat.pick([slugged], user: Self.me, used: []) == nil)
        // Only the pool's numbered names.
        #expect(!CloudStartChat.isLanePool("fs-lane-notes"))
        #expect(!CloudStartChat.isLanePool("lane-vm-"))
    }

    @Test func anIdlePausedMachineOfMineIsFreeAndAPersonsPauseIsNot() {
        let idle = Self.machine("vm-idle", "spare", status: .paused, pause: .idle, connected: false)
        let paused = Self.machine("vm-paused", "kept", status: .paused, pause: .user, connected: false)
        let failed = Self.machine("vm-failed", "broken", status: .failed, connected: false)
        #expect(CloudStartChat.pick([paused, failed, idle], user: Self.me, used: []) == "vm-idle")
        // A connected free machine comes before one that must resume.
        #expect(CloudStartChat.pick([idle, Self.machine("vm-live", "live")], user: Self.me, used: []) == "vm-live")
    }

    @Test func aMachineWithNoCreatorCountsAsMineOnlyWhenAnEarlierSendRanThere() {
        let unknown = Self.machine("vm-x", "cloud-chats", by: nil)
        #expect(CloudStartChat.pick([unknown], user: Self.me, used: []) == nil)
        #expect(CloudStartChat.pick([unknown], user: Self.me, used: ["vm-x"]) == "vm-x")
    }

    @Test func aNewMachineForChatsGetsAFreeName() {
        #expect(CloudStartChat.newMachineName(taken: ["fs-lane-1"]) == "cloud-chats")
        #expect(CloudStartChat.newMachineName(taken: ["Cloud-Chats", "cloud-chats-2"]) == "cloud-chats-3")
    }

    /// #28845: the first try took vm-a; then vm-a dropped its link and the list's order changed, so
    /// a fresh pick would take vm-b. The retry still goes to vm-a, where its tab key gets the first
    /// try's tab back.
    @Test func aRetryOfTheSameSendStaysOnItsFirstTrysMachine() {
        let destinations = CloudStartChat.Destinations()
        let key = UUID().uuidString
        let first = [Self.machine("vm-a", "spare-a"), Self.machine("vm-b", "spare-b")]
        let firstTry = CloudStartChat.destination(for: key, destinations: destinations, candidates: first, user: Self.me) { _ in true }
        #expect(firstTry == .machine("vm-a"))
        destinations.record("vm-a", for: key)

        let later = [Self.machine("vm-b", "spare-b"), Self.machine("vm-a", "spare-a", connected: false)]
        #expect(CloudStartChat.destination(for: key, destinations: destinations, candidates: later, user: Self.me) { _ in true } == .machine("vm-a"))
        // The same key in another case is the same send.
        #expect(CloudStartChat.destination(for: key.lowercased(), destinations: destinations, candidates: later, user: Self.me) { _ in nil } == .machine("vm-a"))
        // Another send picks afresh.
        #expect(CloudStartChat.destination(for: UUID().uuidString, destinations: destinations, candidates: later, user: Self.me) { _ in true } == .machine("vm-b"))
    }

    @Test func aRetryWhoseMachineIsGonePicksAfreshAndARetryOfANewMachineStaysOnIt() {
        let destinations = CloudStartChat.Destinations()
        let key = UUID().uuidString
        destinations.record("vm-gone", for: key)
        let now = [Self.machine("vm-b", "spare-b")]
        #expect(CloudStartChat.destination(for: key, destinations: destinations, candidates: now, user: Self.me) { $0 != "vm-gone" } == .machine("vm-b"))
        #expect(destinations.machine(for: key) == nil)
        // A machine made for the first try (not listed yet) is kept for its retry.
        destinations.record("vm-new", for: key)
        #expect(CloudStartChat.destination(for: key, destinations: destinations, candidates: now, user: Self.me) { _ in nil } == .machine("vm-new"))
    }

    @Test func destinationsSurviveARelaunchAndKeepOnlyTheNewest() throws {
        let suite = "cn-start-chat-\(UUID().uuidString.prefix(8))"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let kept = CloudStartChat.Destinations()
        kept.defaults = { defaults }
        let keys = (0...CloudStartChat.Destinations.limit).map { _ in UUID().uuidString }
        for (index, key) in keys.enumerated() { kept.record("vm-\(index)", for: key) }

        let relaunched = CloudStartChat.Destinations()
        relaunched.defaults = { defaults }
        #expect(relaunched.machine(for: keys[0]) == nil)
        #expect(relaunched.machine(for: keys[1]) == "vm-1")
        #expect(relaunched.machine(for: keys.last!) == "vm-\(CloudStartChat.Destinations.limit)")
        #expect(relaunched.machines.count == CloudStartChat.Destinations.limit)
    }

    /// A retry after the copy finished opens its chat without copying again: a second push would
    /// overwrite what the chat already changed on the machine.
    @Test func aFinishedCopyIsKeptPerSendAndMachineAcrossARelaunch() throws {
        let suite = "cn-start-chat-copy-\(UUID().uuidString.prefix(8))"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CloudStartChat.Destinations()
        first.defaults = { defaults }
        let key = UUID().uuidString
        first.record("vm-a", for: key)
        #expect(first.copiedChat(for: key, on: "vm-a") == nil)
        first.recordCopy("/home/cmux/work/chats/k/paint", for: key, on: "vm-a")
        // Pinning the same machine again (the retry) keeps the finished copy.
        first.record("vm-a", for: key)

        let relaunched = CloudStartChat.Destinations()
        relaunched.defaults = { defaults }
        #expect(relaunched.copiedChat(for: key.lowercased(), on: "vm-a") == "/home/cmux/work/chats/k/paint")
        // Another machine (the first one is gone) has no copy of this send yet.
        #expect(relaunched.copiedChat(for: key, on: "vm-b") == nil)
        relaunched.record("vm-b", for: key)
        #expect(relaunched.copiedChat(for: key, on: "vm-a") == nil)
        #expect(relaunched.copiedChat(for: key, on: "vm-b") == nil)
        #expect(relaunched.copiedChat(for: UUID().uuidString, on: "vm-a") == nil)
    }

    /// A folder the page named is copied only as the pane checked it.
    @Test func aPageNamedFolderIsCopiedOnlyAsItsCheckedUploadRoot() throws {
        let folder = try #require(CloudMoveFolder(chat: "/Users/me/src/paint"))
        var start = try #require(AgentPaneCloudStart(params: ["task": "t", "cwd": "/Users/me/src/paint", "key": UUID().uuidString]))
        #expect(!CloudStartChat.uploads(folder, as: start))
        start.uploadRoot = folder.root
        #expect(CloudStartChat.uploads(folder, as: start))
        start.uploadRoot = "/Users/me/src/paint/sub"
        #expect(!CloudStartChat.uploads(folder, as: start))
        // The tab's own folder (no `cwd`): only that folder itself, never a working copy above it.
        let tabs = try #require(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString]))
        #expect(CloudStartChat.uploads(folder, as: tabs))
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("cn-start-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: repo) }
        let project = repo.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let inRepo = try #require(CloudMoveFolder(chat: project.path))
        #expect(!inRepo.subpath.isEmpty)
        #expect(!CloudStartChat.uploads(inRepo, as: tabs))
        let atRoot = try #require(CloudMoveFolder(chat: repo.path))
        #expect(CloudStartChat.uploads(atRoot, as: tabs))
        // Never the home folder or a folder above it (a tab in /Users), whatever `isTooBroad` says.
        let users = try #require(CloudMoveFolder(chat: "/Users"))
        #expect(!CloudStartChat.uploads(users, as: tabs, home: "/Users/me"))
        let home = try #require(CloudMoveFolder(chat: "/Users/me"))
        #expect(!CloudStartChat.uploads(home, as: tabs, home: "/Users/me"))
        #expect(!CloudStartChat.uploads(try #require(CloudMoveFolder(chat: "/")), as: tabs, home: "/Users/me"))
        #expect(CloudStartChat.uploads(atRoot, as: tabs, home: "/Users/me"))
    }

    /// The create's key is the send's, so a retry after a lost create answer never makes a second VM.
    @Test func aNewMachineIsCreatedUnderTheSendsKey() throws {
        let key = UUID().uuidString
        let start = try #require(AgentPaneCloudStart(params: ["task": "t", "key": key]))
        let request = CloudStartChat.createRequest(for: start, sizedFor: nil)
        #expect(request.idempotencyKey == "cloud-start-chat-" + key.lowercased())
        let retry = try #require(AgentPaneCloudStart(params: ["task": "t", "key": key.uppercased()]))
        #expect(CloudStartChat.createRequest(for: retry, sizedFor: nil).idempotencyKey == request.idempotencyKey)
        #expect(!request.wasSent)
    }

    /// Not behind Labs (Leo, 2026-10-30: "that seems dumb. i dont like putting so much stuff in
    /// labs"): only Cloud off by policy and a signed-out account refuse.
    @Test func aCloudStartIsRefusedOnlyWhenCloudIsOffOrNobodyIsSignedIn() {
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: true) == nil)
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: false) == "not_signed_in")
        #expect(CloudStartChat.refusal(cloudDisabled: true, signedIn: true) == "cloud_disabled")
        #expect(CloudStartChat.refusal(cloudDisabled: true, signedIn: false) == "cloud_disabled")
        // The Cloud app server's link takes no folder copy: refused before a machine is created.
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: true, appServerLink: true) == "unavailable")
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: false, appServerLink: true) == "not_signed_in")
    }

    /// A retry finds its own copy's folder; one whose record is gone gets a new folder, so its copy
    /// never writes over a chat that already started in the old one.
    @Test func aRetryWhoseRecordWasEvictedCopiesIntoANewFolder() {
        let destinations = CloudStartChat.Destinations()
        let key = UUID().uuidString
        var minted = 0
        let fresh = { () -> String in minted += 1; return "chats/\(key.lowercased())/\(minted)" }
        destinations.record("vm-a", for: key)
        let first = destinations.place(for: key, on: "vm-a", fresh: fresh)
        // The same send again (its copy cut off, or done and the tab lost): the same folder.
        #expect(destinations.place(for: key, on: "vm-a", fresh: fresh) == first)
        destinations.recordCopy("/home/cmux/work/" + first + "/paint", for: key, on: "vm-a")
        #expect(destinations.place(for: key, on: "vm-a", fresh: fresh) == first)
        // Pushed out by newer sends: the next try gets a folder of its own, never the old one.
        for _ in 0..<CloudStartChat.Destinations.limit { destinations.record("vm-b", for: UUID().uuidString) }
        #expect(destinations.copiedChat(for: key, on: "vm-a") == nil)
        let again = destinations.place(for: key, on: "vm-a", fresh: fresh)
        #expect(again != first)
        #expect(minted == 2)
    }
}
