import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-6bgzj at the page's op boundary: a chat reopens where the reader left it after a relaunch or
/// a crash. A settled scroll's `chat.scrollAnchor` reaches the file beside the launch snapshot, and
/// the next run's `chat.scrollAnchor.get` for that chat hands the place back; at the latest message
/// there is nothing to keep.
@Suite(.serialized)
@MainActor
struct ChatScrollRestoreTests {
    static let context = PageCallContext(page: PageDescriptor.agent.id)

    static func call(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let provider = AgentPageProvider { _ in nil }
        return try await provider.call(AgentPageOps.namespace + method, params: .object(params), context: context)
    }

    @Test func aChatReopensWhereItRestedAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scroll-anchors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }

        // This run: the reader scrolls chat s-1 up and it rests on row user-42.
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .string("user-42"), "offset": .number(120.5)])

        // The next run (after kill -9 or a reboot) reads it back from disk for that chat only.
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))
        let place = try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")])
        #expect(place == .object(["rowId": .string("user-42"), "offset": .number(120.5)]))
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-2")]) == .null)

        // Back at the latest message: the place is forgotten, so the chat opens following the reply.
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .null, "offset": .number(0)])
        await AgentPaneScrollAnchors.shared?.flushed()  // the last store\'s saves are on disk
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors"))
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")]) == .null)
    }

    /// #25852 (threading item 1, main-thread blocking): a settled scroll's save is encoded and written on the
    /// files lane, never on the main thread.
    @Test func aChatsPlaceIsSavedOffTheMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scroll-anchors-main-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        // concurrency-allow: test recorder written by the lane thread, read after flushed() (lock carve-out).
        let onMain = Mutex<[Bool]>([])
        let anchors = AgentPaneScrollAnchors(directory: directory, work: BackgroundWork(label: "test.scroll-anchors")) { url, data in
            onMain.withLock { $0.append(Thread.isMainThread) }
            StateFileWriter.disk(url, data)
        }
        AgentPaneScrollAnchors.shared = anchors
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-9"), "rowId": .string("user-1"), "offset": .number(4)])
        await anchors.flushed()
        #expect(onMain.withLock { $0 } == [false], "a place was written on the main thread")
    }

    @Test func anOpWithoutAChatIsRefused() async throws {
        await #expect(throws: PageError.self) { _ = try await Self.call("chat.scrollAnchor.get", [:]) }
    }
}
