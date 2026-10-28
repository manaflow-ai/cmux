import CmuxNextAgentPane
import CmuxNextDesign
import Dispatch
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-z5vd: a new chat's typed text, from before it has an acpmux session, comes back after a
/// relaunch. The page's `chat.unsentDraft` reaches the tab's kept drafts on disk, and the next run
/// opens that tab as the chat with the text as its draft (not as the New Tab page). Once the chat
/// has a session, acpmux keeps its draft and the tab's copy is gone.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UnsentDraftTests {
    static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func aNewChatsTypedTextComesBackAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)

        // This run's drafts, held as the tab store holds them.
        let work = BackgroundWork()
        let drafts = AgentUnsentDrafts(file: file, work: work)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "compare the two retry policies"]))

        // The next run's tab, still without a session, opens as the chat with its draft.
        await drafts.flush()
        let relaunched = AgentUnsentDrafts(file: file)
        let seed = try #require(relaunched.seed(for: "tab-1", session: nil))
        #expect(await seed.take()?.draft == "compare the two retry policies")
        #expect(relaunched.seed(for: "tab-1", session: "s-1") == nil, "a chat with a session keeps its draft in acpmux")
        #expect(relaunched.seed(for: "tab-2", session: nil) == nil)

        // The first prompt starts the chat's session: the tab's copy goes, and later text is acpmux's.
        _ = await model.respond(to: Self.request("chat.persistSession", ["sessionId": "s-1"]))
        await work.shutdown()
        #expect(AgentUnsentDrafts(file: file).seed(for: "tab-1", session: nil) == nil)
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "later"]))
        await drafts.flush()
        #expect(AgentUnsentDrafts(file: file).seed(for: "tab-1", session: nil) == nil)
        withExtendedLifetime(drafts) {}
    }

    @Test(arguments: [false, true], ["last draft", ""])
    func committedQuitDrainsDraftsBeforeBrowserStop(ends: Bool, text: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let queued = AsyncStream.makeStream(of: Void.self)
        let work = BackgroundWork(onQueued: { _, _ in queued.continuation.yield(()) })
        let release = DispatchSemaphore(value: 0)
        work.post(.userVisible, mayBlock: .files) { release.wait() }
        defer { release.signal(); queued.continuation.finish() }
        let drafts = AgentUnsentDrafts(file: file, work: work)
        var stopped = false
        let quit = Task { await QuitCompletion.run(ends ? .endKeepLayout : .keep, remember: false, QuitSteps(
            remember: { _ in },
            prepareWindows: { drafts.set("earlier", for: "tab") },
            endLocalSessions: { _ in drafts.set("during session end", for: "tab"); return [] },
            confirmFailures: { _ in .quitAnyway },
            finalizeDrafts: {
                drafts.set(text, for: "tab")
                await drafts.finalizeForQuit()
            },
            stopBrowserEngines: {
                // Even callbacks queued while the final save awaited cannot become new producers.
                drafts.set("too late", for: "tab")
                drafts.move("tab", to: "other")
                await drafts.flush()
                let saved = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
                #expect(saved?["tab"] == text)
                #expect(saved?["other"] == nil)
                stopped = true
            }
        )) }
        // Saves plus the final fence are queued behind the held files lane.
        var iterator = queued.stream.makeAsyncIterator()
        for _ in 0..<(ends ? 4 : 3) { await iterator.next() }
        #expect(!stopped, "quit reached browser shutdown while its draft save was blocked")
        drafts.set("late callback during drain", for: "tab")
        release.signal()
        await quit.value
        #expect(stopped)
    }

    private final class UnsavedFile: QuitUnsavedParticipant {
        let quitParticipantID = "file:local:/tmp/unsent-quit-cancel"
        let quitTitle = "notes.md"
        let hasUnsavedChanges = true
        func flushForQuit() async throws {}
        func discardForQuit() async {}
    }

    @Test func cancelledQuitLeavesDraftsWritable() async {
        let participant = UnsavedFile()
        let registry = QuitUnsavedRegistry()
        let registration = registry.register(participant)
        let center = CmuxDialogCenter(host: CmuxDialogHeadlessHost())
        let token = center.observe { event in
            if case .opened(let record) = event { center.press(record.id, button: "cancel") }
        }
        defer { center.stopObserving(token); registration.cancel() }
        let drafts = AgentUnsentDrafts(file: nil)
        let proceeds = await QuitUnsavedStep.resolve(.interactive, registry: registry, scope: .app,
                                                     center: center, writeDrafts: {})
        if proceeds { await drafts.finalizeForQuit() }
        drafts.set("after cancelling quit", for: "tab")
        #expect(!proceeds)
        #expect(drafts.hasDraft("tab"))
    }
}
