import CmuxChief
import CmuxHomeCore
import Foundation
import Testing

/// Home's own store over the local Chief, end to end.
@MainActor
@Suite struct ChiefHomeStoreTests {
    func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// The app's start path: the store exists while the owner still loads off the main thread,
    /// and connects when the load ends.
    @Test func storeOverALoadingOwnerConnectsWhenItIsReady() async throws {
        let fixture = ChiefFixture()
        let home = fixture.home
        let gate = Gate()
        let loading = Task<ChiefConversationOwner, any Error> {
            await gate.wait()
            return try await ChiefConversationOwner.load(home: home, brain: FakeBrain.replying(["Hi"]), userDisplayName: "Tester") { _ in
                ChiefTurnContext(systemPrompt: "", workingDirectory: home.root, environment: [:])
            }
        }
        let store = HomeStore(source: ChiefLocalSource(loading: loading),
                              blobCacheDirectory: home.root.appendingPathComponent("client-blobs", isDirectory: true))
        store.start()
        defer { store.stop() }
        #expect(!store.isOnline && store.rows.isEmpty)
        await gate.open()
        #expect(await waitUntil { store.isOnline && store.rows.first?.id == ChiefConversationOwner.defaultConversationID })
    }

    @Test func storeShowsTheChiefAndItsReply() async throws {
        let fixture = ChiefFixture()
        let owner = try fixture.owner(.replying(["Hello", " from Chief"]))
        let blobCache = fixture.home.root.appendingPathComponent("client-blobs", isDirectory: true)
        let store = HomeStore(source: ChiefLocalSource(owner: owner), blobCacheDirectory: blobCache)
        store.start()
        defer { store.stop() }
        #expect(await waitUntil { store.isOnline && !store.rows.isEmpty })
        let id = ChiefConversationOwner.defaultConversationID
        #expect(store.rows.first?.id == id)
        #expect(store.rows.first?.kind == .chief)
        #expect(store.rows.first?.title == "Chief")

        await store.open(id)
        let key = IdempotencyKey("store-send")
        let result = try await store.perform(.sendMessage(conversation: id, parts: [.text("hi from Home")]), key: key)
        #expect(result.replayed == false)
        #expect(await waitUntil {
            store.transcript(for: id).contains { $0.author == ChiefConversationOwner.chiefID && $0.plainText == "Hello from Chief" }
        })
        let items = store.transcript(for: id)
        #expect(items.map(\.plainText) == ["hi from Home", "Hello from Chief"])
        #expect(items.first?.key == key)
        #expect(items.allSatisfy { $0.delivery == .committed })
        #expect(await waitUntil { store.typing[id] == nil && store.drafts[id] == nil })
        #expect(store.summary(id)?.readCursors[ChiefConversationOwner.chiefID] == 1)
    }

    @Test func twoSubscribersSeeTheSameEvents() async throws {
        let owner = try ChiefFixture().owner(.replying(["ok"]))
        let first = EventRecorder()
        let second = EventRecorder()
        await first.start(owner)
        await second.start(owner)
        try await ChiefFixture.send("hello", to: owner)
        _ = try await ChiefFixture.idleMessages(owner, count: 2)
        let both = await ChiefFixture.eventually {
            let a = await first.messages().count
            let b = await second.messages().count
            return a >= 2 && b >= 2
        }
        #expect(both)
        let firstEvents = await first.events
        #expect(firstEvents.first == .connection(.online))
        if case .inbox = firstEvents.dropFirst().first {} else { Issue.record("second event is not the inbox") }
        #expect(await first.messages() == second.messages())
    }
}

@Suite struct ChiefHomeTests {
    let userHome = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func environmentOverrideWins() {
        let home = ChiefHome.resolve(environment: ["CMUX_CHIEF_HOME": "/tmp/chief-test"], userHome: userHome,
                                     bundleID: "com.cmuxterm.app")
        #expect(home.root.path == "/tmp/chief-test")
    }

    @Test func oneHomePerBundleID() {
        let release = ChiefHome.resolve(environment: [:], userHome: userHome, bundleID: "com.cmuxterm.app")
        let dev = ChiefHome.resolve(environment: [:], userHome: userHome, bundleID: "com.cmuxterm.app.debug.my tag")
        let none = ChiefHome.resolve(environment: [:], userHome: userHome, bundleID: nil)
        #expect(release.root.path == "/Users/someone/.cmux/chief/com.cmuxterm.app")
        #expect(dev.root.path == "/Users/someone/.cmux/chief/com.cmuxterm.app.debug.my-tag")
        #expect(none.root.path == "/Users/someone/.cmux/chief/default")
        #expect(release.conversationsDirectory.lastPathComponent == "conversations")
        #expect(release.blobsDirectory.lastPathComponent == "blobs")
        #expect(release.memoryDirectory.lastPathComponent == "memory")
        #expect(release.stateDirectory.lastPathComponent == "state")
    }
}
