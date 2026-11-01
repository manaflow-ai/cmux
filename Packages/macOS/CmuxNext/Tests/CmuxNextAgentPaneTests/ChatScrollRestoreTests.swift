import CmuxNextPages
import CmuxNextSettings
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
        let files = AgentPaneStateFiles()
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }

        // This run: the reader scrolls chat s-1 up and it rests on row user-42.
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, files: files)
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .string("user-42"), "offset": .number(120.5)])

        // The next run (after kill -9 or a reboot) reads it back from disk for that chat only.
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, files: files)
        let place = try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")])
        #expect(place == .object(["rowId": .string("user-42"), "offset": .number(120.5)]))
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-2")]) == .null)

        // Back at the latest message: the place is forgotten, so the chat opens following the reply.
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .null, "offset": .number(0)])
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, files: files)
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")]) == .null)
    }

    @Test func anOpWithoutAChatIsRefused() async throws {
        await #expect(throws: PageError.self) { _ = try await Self.call("chat.scrollAnchor.get", [:]) }
    }
}
