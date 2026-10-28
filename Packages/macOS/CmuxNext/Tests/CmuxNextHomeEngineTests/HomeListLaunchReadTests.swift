import CmuxHomeCore
@testable import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import os
import Testing

/// The Home list's launch files (p08-startup-076): the conversations' `HomeCache` and the list's
/// `HomeSidebarLaunchCache`, read together on a `BackgroundWork` files lane, never on the main thread;
/// `value` is nil while the read runs, so the main thread never waits for it.
@Suite(.timeLimit(.minutes(1))) struct HomeListLaunchReadTests {
    static let owner = "cmux-chief-launch-read-test"
    static let conversation = ConversationID("conv_launch_read")

    static func caches() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("home-list-launch-read-\(UUID().uuidString)", isDirectory: true)
    }

    /// The two files as the last quit left them under `caches`.
    static func lastQuit(caches: URL) async throws {
        let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = HomeCacheSnapshot()
        snapshot.me = me
        snapshot.conversations = [CmuxHomeCore.ConversationSummary(id: conversation, owner: .local, title: "Launch", participants: [me],
                                                                   createdAt: at, updatedAt: at)]
        try await HomeCache.standard(owner: owner, caches: caches).save(snapshot)
        let sidebar = HomeSidebarLaunchCache.standard(owner: owner, caches: caches, files: BackgroundWork())
        sidebar.save(HomeSidebarLaunchSnapshot(account: "acct_test", archivedChiefs: ["agent_old"]))
        sidebar.flush()
    }

    @Test func theReadHoldsBothFilesAndRunsOffTheMainThread() async throws {
        let caches = Self.caches()
        try await Self.lastQuit(caches: caches)
        let onMain = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let conversations = HomeCache.standard(owner: Self.owner, caches: caches)
        let sidebar = HomeSidebarLaunchCache.standard(owner: Self.owner, caches: caches, files: BackgroundWork())
        let read = HomeListLaunchRead(owner: Self.owner, caches: caches, conversations: conversations, sidebar: sidebar, on: BackgroundWork()) {
            onMain.withLock { $0.append(Thread.isMainThread) }
            return HomeListLaunchRead.Value(conversations: conversations.load(), sidebar: sidebar.read())
        }
        let value = await read.finished()
        #expect(onMain.withLock { $0 } == [false], "the launch read ran on the main thread")
        #expect(value.conversations?.conversations.map(\.id) == [Self.conversation])
        #expect(value.sidebar?.account == "acct_test")
        #expect(value.sidebar?.archivedChiefs == ["agent_old"])
    }

    /// `start` reads the same files the Home store and list write through: an unchanged list is not written again.
    @Test func startReadsTheOwnersFilesUnderItsCaches() async throws {
        let caches = Self.caches()
        try await Self.lastQuit(caches: caches)
        let read = HomeListLaunchRead.start(owner: Self.owner, caches: caches, on: BackgroundWork())
        let value = await read.finished()
        #expect(value.conversations?.conversations.map(\.id) == [Self.conversation])
        #expect(value.sidebar?.archivedChiefs == ["agent_old"])
        #expect(read.conversations.url == HomeCache.standard(owner: Self.owner, caches: caches).url)
        #expect(read.sidebar.url == HomeSidebarLaunchCache.standard(owner: Self.owner, caches: caches, files: BackgroundWork()).url)
        #expect(read.reads(owner: Self.owner, caches: caches))
        #expect(!read.reads(owner: "cmux-chief-other", caches: caches))
        #expect(!read.reads(owner: Self.owner, caches: Self.caches()))
    }

    /// A slow disk: the value is nil while the read runs (nothing waits for it), and the read ends once the disk answers.
    @Test func aSlowReadHasNoValueUntilItEnds() async throws {
        let caches = Self.caches()
        let gate = DispatchSemaphore(value: 0)
        let read = HomeListLaunchRead(owner: Self.owner, caches: caches, conversations: HomeCache.standard(owner: Self.owner, caches: caches),
                                      sidebar: HomeSidebarLaunchCache.standard(owner: Self.owner, caches: caches, files: BackgroundWork()), on: BackgroundWork()) {
            gate.wait()
            return HomeListLaunchRead.Value()
        }
        #expect(read.value == nil)
        gate.signal()
        let value = await read.finished()
        #expect(value.conversations == nil && value.sidebar == nil)
        #expect(read.value != nil)
    }

    /// No files yet (a first launch): the read ends with nothing, and creates no file.
    @Test func aFirstLaunchReadsNothing() async throws {
        let caches = Self.caches()
        let value = await HomeListLaunchRead.start(owner: Self.owner, caches: caches, on: BackgroundWork()).finished()
        #expect(value.conversations == nil && value.sidebar == nil)
        #expect(!FileManager.default.fileExists(atPath: caches.path))
    }
}
