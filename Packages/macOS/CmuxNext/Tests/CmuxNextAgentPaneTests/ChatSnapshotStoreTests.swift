import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The chats' drawn copies (``AgentPaneChatSnapshots``): what a chat's page last drew is kept on
/// disk and served to the chat's next document as `__snapshot/chat.js`, which draws it before its
/// bundle runs (Leo, 2026-11-07: "we need to make these after-restart things load a lot faster").
/// Kept as the tails are: never for an incognito chat, forgotten with the chat, cleared on sign-out.
@Suite(.serialized)
@MainActor
struct ChatSnapshotStoreTests {
    private static func withDisk(_ body: (AgentPaneTailDisk) async throws -> Void) async rethrows {
        let store = AgentPaneTailCache.shared.snapshots
        let cache = AgentPaneTailCache.shared
        cache.resume()
        let disk = AgentPaneTailDisk(directory: FileManager.default.temporaryDirectory.appending(path: "chat-snapshots-\(UUID().uuidString)"),
                                     files: 3, bytes: AgentPaneChatSnapshots.bytes, accepts: { AgentPaneChatSnapshots.holds($0) })
        let before = store.disk
        store.disk = disk
        defer {
            store.disk = before
            cache.resume()
            try? FileManager.default.removeItem(at: disk.directory)
        }
        try await body(disk)
    }

    private static func put(_ session: String, html: String?, allowed: Bool = true) async throws {
        var params: [String: JSONValue] = ["sessionId": .string(session), "v": .number(1), "width": .number(800)]
        if let html { params["html"] = .string(html) }
        _ = try await AgentPaneTailCache.shared.snapshots.reply("chat.snapshot.put", params: .object(params), op: "cmux.agent.chat.snapshot.put",
                                                          allowed: allowed, pageGeneration: AgentPaneTailCache.shared.generation)
    }

    private static func get(_ session: String, allowed: Bool = true) async throws -> JSONValue {
        try await AgentPaneTailCache.shared.snapshots.reply("chat.snapshot.get", params: .object(["sessionId": .string(session)]),
                                                      op: "cmux.agent.chat.snapshot.get", allowed: allowed,
                                                      pageGeneration: AgentPaneTailCache.shared.generation)
    }

    private static func served(_ resources: AgentPageResources) async -> String? {
        let url = URL(string: "cmux-page://cmux.agent/__snapshot/chat.js")!
        let request = PageResourceRequest(prefix: "__snapshot", path: ["chat.js"], url: url)
        guard let answer = await resources.rangedResource(for: request, range: nil) else { return nil }
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == "text/javascript")
        return String(data: answer.data, encoding: .utf8)
    }

    /// A page's copy is kept for the next launch and read back as the page wrote it, without its session id.
    @Test func aWrittenCopyIsReadBack() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-1", html: "<main id=\"root\">hi</main>")
            await disk.settled()
            let kept = try await Self.get("s-1")
            #expect(kept["html"]?.stringValue == "<main id=\"root\">hi</main>")
            #expect(kept["width"]?.doubleValue == 800)
            #expect(kept["sessionId"] == nil)
        }
    }

    /// The next document of the chat gets it as the script it runs before its bundle; a page with no
    /// chat yet, or a chat with none, gets null and draws nothing.
    @Test func theDocumentIsServedItsChatsCopy() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-2", html: "<main>chat</main>")
            await disk.settled()
            var session: String? = "s-2"
            let resources = AgentPageResources(session: { session }, allowed: { true })
            resources.themeKey = { "theme-1" }
            let script = try #require(await Self.served(resources))
            #expect(script.hasPrefix("self.__cmuxChatSnapshot={"))
            #expect(script.contains(";self.__cmuxChatSnapshotWhy=\"kept\";"))
            #expect(script.contains("<main>chat</main>"))
            // With the theme the page gets now: a copy drawn under another one is not drawn.
            #expect(script.hasSuffix(";self.__cmuxChatSnapshotTheme=\"theme-1\";"))
            session = nil
            #expect(await Self.served(resources) == "self.__cmuxChatSnapshot=null;self.__cmuxChatSnapshotWhy=\"no-chat\";self.__cmuxChatSnapshotTheme=\"theme-1\";")
            session = "other"
            #expect(await Self.served(resources) == "self.__cmuxChatSnapshot=null;self.__cmuxChatSnapshotWhy=\"none\";self.__cmuxChatSnapshotTheme=\"theme-1\";")
        }
    }

    /// An incognito chat's page is never kept and never served.
    @Test func anIncognitoChatKeepsNothing() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-3", html: "<main>secret</main>", allowed: false)
            await disk.settled()
            #expect(await disk.read("s-3") == nil)
            try await Self.put("s-3", html: "<main>shown</main>")
            await disk.settled()
            #expect(try await Self.get("s-3", allowed: false) == .null)
            let resources = AgentPageResources(session: { "s-3" }, allowed: { false })
            #expect(await Self.served(resources) == "self.__cmuxChatSnapshot=null;self.__cmuxChatSnapshotWhy=\"not-kept-here\";self.__cmuxChatSnapshotTheme=\"\";")
        }
    }

    /// A put with no markup forgets the chat's copy (the page forgot the chat, or its window grew too large).
    @Test func aPutWithoutMarkupForgetsIt() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-4", html: "<main>a</main>")
            try await Self.put("s-4", html: nil)
            await disk.settled()
            #expect(try await Self.get("s-4") == .null)
        }
    }

    /// Sign-out clears the copies with the tails, and a page from before it writes nothing after.
    @Test func signOutClearsThem() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-5", html: "<main>a</main>")
            await disk.settled()
            let stale = AgentPaneTailCache.shared.generation
            AgentPaneTailCache.shared.clear()
            await disk.settled()
            AgentPaneTailCache.shared.resume()
            #expect(try await Self.get("s-5") == .null)
            _ = try await AgentPaneTailCache.shared.snapshots.reply("chat.snapshot.put",
                                                              params: .object(["sessionId": .string("s-5"), "v": .number(1), "html": .string("<main>old</main>")]),
                                                              op: "cmux.agent.chat.snapshot.put", allowed: true, pageGeneration: stale)
            await disk.settled()
            #expect(await disk.read("s-5") == nil)
        }
    }

    /// The theme event carries a key of what it sets, the same for the same theme, which a copy is drawn under.
    @Test func theThemeEventCarriesAStableKey() throws {
        let tokens = ThemeTokens.unresolved
        let first = try #require(AgentPageEvent.theme(tokens, surface: .agentPane))
        let again = try #require(AgentPageEvent.theme(tokens, surface: .agentPane))
        let key = try #require(first.value["key"]?.stringValue)
        #expect(key.count == 32)
        #expect(again.value["key"]?.stringValue == key)
    }

    /// The page's ops are the page host's (the contract both sides check).
    @Test func theOpsAreServed() {
        #expect(AgentPageOps.method(for: "cmux.agent.chat.snapshot.put") == "chat.snapshot.put")
        #expect(AgentPageOps.method(for: "cmux.agent.chat.snapshot.get") == "chat.snapshot.get")
        #expect(PageDescriptor.agent.dynamicPrefixes.contains("__snapshot"))
    }
}
