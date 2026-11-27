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

    static func call(_ method: String, _ params: [String: JSONValue], tab: String? = nil) async throws -> JSONValue {
        let provider = AgentPageProvider { _ in nil }
        provider.tabKey = { tab }
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

    /// One chat open in two tabs at once (Leo, 2026-11-03: "right split is fine on click by default
    /// (extra view doesn't really affect anything)"): each tab's reload reopens where that tab rested,
    /// never where the other one did, and a tab at the latest message stays there.
    @Test func twoTabsOfOneChatKeepTheirOwnPlaceAcrossAReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scroll-anchors-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = AgentPaneStateFiles()
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, files: files)
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .string("user-3"), "offset": .number(10)], tab: "tab-A")
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .string("user-90"), "offset": .number(4)], tab: "tab-B")

        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, files: files)
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], tab: "tab-A")
            == .object(["rowId": .string("user-3"), "offset": .number(10)]))
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], tab: "tab-B")
            == .object(["rowId": .string("user-90"), "offset": .number(4)]))

        // Tab A goes back to the latest message: its reload follows the reply, not tab B's place.
        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .null, "offset": .number(0)], tab: "tab-A")
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, files: files)
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], tab: "tab-A") == .null)
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], tab: "tab-B")
            == .object(["rowId": .string("user-90"), "offset": .number(4)]))
    }

    /// A place saved before places were per tab (no tab in its entry) stays the chat's: a tab with no
    /// place of its own reopens there, and once it settles a scroll it keeps its own.
    @Test func aTabWithNoPlaceOfItsOwnReadsTheChatsOldPlace() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "scroll-anchors-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = AgentPaneStateFiles()
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        let old = #"[{"sessionId":"s-1","anchor":{"rowId":"user-7","offset":3}}]"#
        try Data(old.utf8).write(to: directory.appending(path: AgentPaneScrollAnchors.fileName))
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, files: files)
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], tab: "tab-A")
            == .object(["rowId": .string("user-7"), "offset": .number(3)]))

        _ = try await Self.call("chat.scrollAnchor", ["sessionId": .string("s-1"), "rowId": .string("user-12"), "offset": .number(1)], tab: "tab-A")
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory, files: files)
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")], tab: "tab-A")
            == .object(["rowId": .string("user-12"), "offset": .number(1)]))
        // No page that is no tab's loses the chat's place either.
        #expect(try await Self.call("chat.scrollAnchor.get", ["sessionId": .string("s-1")]) != .null)
    }
}
