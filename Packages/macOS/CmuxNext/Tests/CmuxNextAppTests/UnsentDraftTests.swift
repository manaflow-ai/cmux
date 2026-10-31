import CmuxNextAgentPane
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-z5vd: a new chat's typed text, from before it has an acpmux session, comes back after a
/// relaunch. The page's `chat.unsentDraft` reaches the tab's kept drafts on disk, and the next run
/// opens that tab as the chat with the text as its draft (not as the New Tab page). Once the chat
/// has a session, acpmux keeps its draft and the tab's copy is gone.
@MainActor
struct UnsentDraftTests {
    private static func until(_ ready: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
        while !ready(), clock.now < deadline { await Task.yield() }
        return ready()
    }

    static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func aNewChatsTypedTextComesBackAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)

        // This run's drafts, held as the tab store holds them.
        let work = BackgroundWork(label: "test.unsent-drafts")
        let drafts = AgentUnsentDrafts(file: file, work: work)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "compare the two retry policies"]))
        await drafts.flushed()

        // The next run's tab, still without a session, opens as the chat with its draft.
        let relaunched = AgentUnsentDrafts(file: file, work: nil)
        let seed = try #require(relaunched.seed(for: "tab-1", session: nil))
        #expect(await seed.take()?.draft == "compare the two retry policies")
        #expect(relaunched.seed(for: "tab-1", session: "s-1") == nil, "a chat with a session keeps its draft in acpmux")
        #expect(relaunched.seed(for: "tab-2", session: nil) == nil)

        // The first prompt starts the chat's session: the tab's copy goes, and later text is acpmux's.
        _ = await model.respond(to: Self.request("chat.persistSession", ["sessionId": "s-1"]))
        await drafts.flushed()
        #expect(AgentUnsentDrafts(file: file, work: nil).seed(for: "tab-1", session: nil) == nil)
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "later"]))
        await drafts.flushed()
        #expect(AgentUnsentDrafts(file: file, work: nil).seed(for: "tab-1", session: nil) == nil)
        withExtendedLifetime(drafts) {}
    }

    @Test func aDraftDuringEngineStopIsRefusedAfterTheFinalDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let work = BackgroundWork(label: "test.unsent-drafts-quit")
        let drafts = AgentUnsentDrafts(file: file, work: work)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        let accepted = await model.respond(to: Self.request("chat.unsentDraft", ["text": "before engine stop"]))
        #expect(accepted["ok"] as? Bool == true)
        await AgentPanePersistenceQuit(drafts: drafts, anchors: nil, work: work).drain()

        // CEF shutdown can now suspend while the WebKit bridge still pumps page requests.
        let late = await model.respond(to: Self.request("chat.unsentDraft", ["text": "after the final drain"]))
        #expect(late["ok"] as? Bool == false, "a save cannot be acknowledged after the quit's last drain")
        await work.shutdown() // test cleanup also drains the unfixed implementation's late save
        let relaunched = AgentUnsentDrafts(file: file, work: nil)
        #expect(await relaunched.seed(for: "tab-1", session: nil)?.take()?.draft == "before engine stop")
    }

    @Test(arguments: [false, true])
    func aPendingTabsAcceptedDraftFollowsItsRealIDDuringQuit(abandoned: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let work = BackgroundWork(label: "test.unsent-drafts-identity")
        let drafts = AgentUnsentDrafts(file: file, work: work)
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: [:], showcase: true,
                                 defaults: UserDefaults())
        tabs.unsentDrafts = drafts
        let provisional = ProvisionalTab().id
        tabs.track(provisional, in: DaemonStore())
        defer { tabs.release("tab-real"); tabs.release(provisional) }
        let text = "accepted while the tab was still being created"
        #expect(drafts.set(text, for: provisional))
        await drafts.flushed()

        var quitFinished = false
        let quit = Task {
            await AgentPanePersistenceQuit(drafts: drafts, anchors: nil, work: work).drain()
            quitFinished = true
        }
        // Observe the public refusal boundary, without sleeps or a test-only quit hook. Repeating
        // the unchanged text queues no save while the quit task gets its main-actor turn.
        #expect(await Self.until { !drafts.set(text, for: provisional) }, "quit did not seal new edits")
        #expect(!quitFinished, "quit must settle an accepted draft's identity before its final drain")
        // The pending create's reply or event echo uses this same rekey path while quit awaits.
        if abandoned { tabs.release(provisional) } else { tabs.rekey(provisional, to: "tab-real") }
        await quit.value

        let relaunched = AgentUnsentDrafts(file: file, work: nil)
        #expect(await relaunched.seed(for: "tab-real", session: nil)?.take()?.draft == (abandoned ? nil : text))
        #expect(relaunched.seed(for: provisional, session: nil) == nil)
        await work.shutdown() // cleanup happens only after the durability assertions
    }

    @Test func aPendingTabWithoutADraftDoesNotKeepQuitWaiting() async {
        let drafts = AgentUnsentDrafts(file: nil, work: nil)
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: [:], showcase: true,
                                 defaults: UserDefaults())
        tabs.unsentDrafts = drafts
        let provisional = ProvisionalTab().id
        tabs.track(provisional, in: DaemonStore())
        var quitFinished = false
        let quit = Task {
            await AgentPanePersistenceQuit(drafts: drafts, anchors: nil, work: nil).drain()
            quitFinished = true
        }
        let finishedWithoutIdentity = await Self.until { quitFinished }
        tabs.release(provisional) // also cleans up a broken implementation that waited for an empty draft
        await quit.value
        #expect(finishedWithoutIdentity)
    }

    /// #25852 (threading item 1, main-thread blocking): a draft holds up to a million characters and is saved
    /// on every settled edit; its encode and write run on the files lane, never on the main thread, and the
    /// quit's `BackgroundWork.shutdown()` still puts the last edit on disk.
    @Test func aDraftIsSavedOffTheMainThreadAndTheQuitKeepsTheLastEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-main-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        // concurrency-allow: test recorder written by the lane thread, read after the shutdown (lock carve-out).
        let onMain = Mutex<[Bool]>([])
        let work = BackgroundWork(label: "test.unsent-drafts")
        let drafts = AgentUnsentDrafts(file: file, work: work) { url, data in
            onMain.withLock { $0.append(Thread.isMainThread) }
            StateFileWriter.disk(url, data)
        }
        drafts.set("first words", for: "tab-1")
        drafts.set("first words, then more", for: "tab-1")
        await work.shutdown()

        #expect(!onMain.withLock { $0 }.isEmpty)
        #expect(onMain.withLock { $0 }.allSatisfy { !$0 }, "a draft was written on the main thread")
        let relaunched = AgentUnsentDrafts(file: file, work: nil)
        #expect(await relaunched.seed(for: "tab-1", session: nil)?.take()?.draft == "first words, then more")
    }
}
