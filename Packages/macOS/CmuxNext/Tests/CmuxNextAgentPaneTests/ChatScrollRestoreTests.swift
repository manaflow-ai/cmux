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

    /// A page's call on a provider given `anchors` by init, as each agent pane's is (nil keeps no places).
    static func call(_ method: String, _ params: [String: JSONValue], anchors: AgentPaneScrollAnchors?) async throws -> JSONValue {
        let provider = AgentPageProvider(chatStores: AgentPaneChatStores(scrollAnchors: anchors, draftAttachments: nil), mainWork: AgentPaneMainThread.standalone().mainWork) { _ in nil }
        return try await provider.call(AgentPageOps.namespace + method, params: .object(params), context: context)
    }

    @Test func aChatReopensWhereItRestedAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scroll-anchors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // This run: the reader scrolls chat s-1 up and it rests on row user-42.
        let run = AgentPaneScrollAnchors(directory: directory)
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .string("user-42"), "offset": .number(120.5)],
                                anchors: run)

        // The next run (after kill -9 or a reboot) reads it back from disk for that chat only.
        let next = AgentPaneScrollAnchors(directory: directory)
        let place = try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], anchors: next)
        #expect(place == .object(["rowId": .string("user-42"), "offset": .number(120.5)]))
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-2")], anchors: next) == .null)

        // Back at the latest message: the place is forgotten, so the chat opens following the reply.
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .null, "offset": .number(0)], anchors: next)
        let after = AgentPaneScrollAnchors(directory: directory)
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], anchors: after) == .null)
    }

    @Test func anOpWithoutAChatIsRefused() async throws {
        await #expect(throws: PageError.self) { _ = try await Self.call("chat.scrollAnchor.get", [:], anchors: nil) }
    }

    /// A provider made with no stores (a test host, the gallery) keeps no place and answers none.
    @Test func aProviderWithNoStoresKeepsNoPlace() async throws {
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .string("user-1"), "offset": .number(4)], anchors: nil)
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], anchors: nil) == .null)
    }
}
