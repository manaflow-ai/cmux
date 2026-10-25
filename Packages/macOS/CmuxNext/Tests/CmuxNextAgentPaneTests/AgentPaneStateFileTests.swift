@testable import CmuxNextAgentPane
import CmuxNextCompat
import Foundation
import Testing

/// The agent pane's two small state files (each chat's scroll place, each new chat's unsent draft)
/// are written after a user action: a settled scroll, a settled edit. The write runs off the main
/// thread, in the order the states were made (the newest state is what stays on disk), and quit's
/// flush returns only when the newest state is there.
@MainActor @Suite struct AgentPaneStateFileTests {
    /// Records each write and remove with the thread it ran on.
    nonisolated final class Recorder: AgentPaneStateFileWriting {
        nonisolated struct Call: Sendable {
            var data: Data?
            var onMain: Bool
        }

        let calls = Mutex<[Call]>([])

        func write(_ data: Data, to url: URL) {
            calls.withLock { $0.append(Call(data: data, onMain: Thread.isMainThread)) }
        }

        func remove(_ url: URL) {
            calls.withLock { $0.append(Call(data: nil, onMain: Thread.isMainThread)) }
        }

        var recorded: [Call] { calls.withLock { $0 } }
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
        let file = AgentPaneStateFile<[String: String]>(url: try Self.directory().appending(path: "state.json"), writer: recorder)
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
