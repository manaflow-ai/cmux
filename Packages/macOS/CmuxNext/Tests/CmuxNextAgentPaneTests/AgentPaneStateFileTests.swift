@testable import CmuxNextAgentPane
import CmuxNextCompat
import Dispatch
import Foundation
import Testing

/// The agent pane's two small state files (each chat's scroll place, each new chat's unsent draft)
/// are written after a user action: a settled scroll, a settled edit. The write runs off the main
/// thread, in the order the states were made (the newest state is what stays on disk), and quit's
/// flush returns only when the newest state is there. Each file's writes run on its own serial
/// queue (the actor's executor), never on the cooperative pool, and a change starts its write at
/// once: no delay, timer or coalescing stands between a change and the disk.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AgentPaneStateFileTests {
    /// Records each write and remove with the thread and the dispatch queue it ran on.
    nonisolated final class Recorder: AgentPaneStateFileWriting {
        nonisolated struct Call: Sendable {
            var data: Data?
            var onMain: Bool
            /// The label of the dispatch queue the call ran on.
            var queue: String
        }

        let calls = Mutex<[Call]>([])
        /// Each call as it happens, for a test that waits for the first one without a flush.
        let stream: AsyncStream<Call>
        private let continuation: AsyncStream<Call>.Continuation

        init() {
            let pair = AsyncStream.makeStream(of: Call.self)
            stream = pair.stream
            continuation = pair.continuation
        }

        func write(_ data: Data, to url: URL) { record(data) }

        func remove(_ url: URL) { record(nil) }

        private func record(_ data: Data?) {
            let call = Call(data: data, onMain: Thread.isMainThread, queue: String(cString: __dispatch_queue_get_label(nil)))
            calls.withLock { $0.append(call) }
            continuation.yield(call)
        }

        var recorded: [Call] { calls.withLock { $0 } }

        /// The first call, awaited as it happens.
        func first() async -> Call? {
            for await call in stream { return call }
            return nil
        }
    }

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Off the main thread

    @Test func aSettledScrollWritesItsPlaceOffTheMainThread() async throws {
        let recorder = Recorder()
        let anchors = AgentPaneScrollAnchors(directory: try Self.directory(), writer: recorder)
        anchors.remember(AgentPaneScrollAnchor(rowId: "user-1", offset: 4), for: "s-1")
        anchors.remember(nil, for: "s-1")
        await anchors.flush()
        #expect(!recorder.recorded.isEmpty)
        #expect(recorder.recorded.allSatisfy { !$0.onMain }, "a state file write ran on the main thread")
        #expect(recorder.recorded.last?.data == nil, "the newest state (no place) is the last one written")
    }

    @Test func aSettledEditWritesItsDraftOffTheMainThread() async throws {
        let recorder = Recorder()
        let drafts = AgentUnsentDrafts(file: try Self.directory().appending(path: AgentUnsentDrafts.fileName), writer: recorder)
        drafts.set("compare the retry policies", for: "tab-1")
        drafts.set("", for: "tab-1")
        await drafts.flush()
        #expect(!recorder.recorded.isEmpty)
        #expect(recorder.recorded.allSatisfy { !$0.onMain }, "a state file write ran on the main thread")
        #expect(recorder.recorded.last?.data == nil, "the newest state (no draft) is the last one written")
    }

    // MARK: At once, on its own queue

    /// A typed draft reaches its file with no flush and no clock: the change starts the write itself,
    /// so a crash a moment later still finds it on disk.
    @Test func aDraftChangeStartsItsWriteAtOnceOnTheDraftsQueue() async throws {
        let recorder = Recorder()
        let drafts = AgentUnsentDrafts(file: try Self.directory().appending(path: AgentUnsentDrafts.fileName), writer: recorder)
        drafts.set("compare the retry policies", for: "tab-1")
        let call = try #require(await recorder.first())
        let kept = try JSONDecoder().decode([String: String].self, from: try #require(call.data))
        #expect(kept == ["tab-1": "compare the retry policies"])
        #expect(call.queue == "com.cmuxterm.app.next.agent-pane.unsent-drafts")
        #expect(!call.onMain)
    }

    /// A scroll place too: written at once, on the scroll places' own queue.
    @Test func aScrollChangeStartsItsWriteAtOnceOnTheScrollQueue() async throws {
        let recorder = Recorder()
        let anchors = AgentPaneScrollAnchors(directory: try Self.directory(), writer: recorder)
        anchors.remember(AgentPaneScrollAnchor(rowId: "user-1", offset: 4), for: "s-1")
        let call = try #require(await recorder.first())
        #expect(call.data != nil)
        #expect(call.queue == "com.cmuxterm.app.next.agent-pane.scroll-anchors")
        #expect(!call.onMain)
    }

    /// Every write and remove of either file, flush included, runs on that file's queue.
    @Test func eachFilesWritesRunOnItsOwnQueue() async throws {
        let draftsRecorder = Recorder(), anchorsRecorder = Recorder()
        let directory = try Self.directory()
        let drafts = AgentUnsentDrafts(file: directory.appending(path: AgentUnsentDrafts.fileName), writer: draftsRecorder)
        let anchors = AgentPaneScrollAnchors(directory: directory, writer: anchorsRecorder)
        drafts.set("one", for: "tab-1")
        anchors.remember(AgentPaneScrollAnchor(rowId: "user-1", offset: 1), for: "s-1")
        drafts.set("", for: "tab-1")
        anchors.remember(nil, for: "s-1")
        await drafts.flush()
        await anchors.flush()
        #expect(!draftsRecorder.recorded.isEmpty && !anchorsRecorder.recorded.isEmpty)
        #expect(Set(draftsRecorder.recorded.map(\.queue)) == ["com.cmuxterm.app.next.agent-pane.unsent-drafts"])
        #expect(Set(anchorsRecorder.recorded.map(\.queue)) == ["com.cmuxterm.app.next.agent-pane.scroll-anchors"])
    }

    // MARK: Order

    @Test func ofTwoQuickDraftEditsTheNewerOneStaysOnDisk() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let drafts = AgentUnsentDrafts(file: file)
        drafts.set("first", for: "tab-1")
        drafts.set("second", for: "tab-1")
        await drafts.flush()
        let kept = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        #expect(kept == ["tab-1": "second"])
    }

    @Test func ofTwoQuickScrollsTheNewerPlaceStaysOnDisk() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let anchors = AgentPaneScrollAnchors(directory: directory)
        anchors.remember(AgentPaneScrollAnchor(rowId: "user-1", offset: 1), for: "s-1")
        anchors.remember(AgentPaneScrollAnchor(rowId: "user-2", offset: 2), for: "s-1")
        await anchors.flush()
        #expect(AgentPaneScrollAnchors(directory: directory).anchor(for: "s-1") == AgentPaneScrollAnchor(rowId: "user-2", offset: 2))
    }

    /// The rule under both: a state that reaches the file after a newer one is dropped, so a write
    /// that lost the race to the actor never puts an older state back on disk.
    @Test func anOlderStateThatArrivesLaterIsDropped() async throws {
        let recorder = Recorder()
        let file = AgentPaneStateFile<[String: String]>(url: try Self.directory().appending(path: "state.json"), writer: recorder,
                                                        queue: DispatchSerialQueue(label: "test.agent-pane.state-file", qos: .utility))
        await file.write(["tab-1": "newer"], sequence: 2)
        await file.write(["tab-1": "older"], sequence: 1)
        await file.write(["tab-1": "newer"], sequence: 2)
        let written = try recorder.recorded.map { try JSONDecoder().decode([String: String].self, from: #require($0.data)) }
        #expect(written == [["tab-1": "newer"]])
    }

    // MARK: Flush

    /// Quit awaits the flush: when it returns, the next run reads the newest draft, and a draft that
    /// was cleared last is gone from disk.
    @Test func theFlushReturnsWhenTheNewestStateIsOnDisk() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let drafts = AgentUnsentDrafts(file: file)
        drafts.set("kept at quit", for: "tab-1")
        await drafts.flush()
        let relaunched = try #require(AgentUnsentDrafts(file: file).seed(for: "tab-1", session: nil))
        #expect(await relaunched.take()?.draft == "kept at quit")

        drafts.set("", for: "tab-1")
        await drafts.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path), "the last draft was cleared, so the file is gone")
    }
}
