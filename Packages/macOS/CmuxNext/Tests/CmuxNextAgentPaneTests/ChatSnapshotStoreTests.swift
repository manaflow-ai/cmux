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

    @discardableResult
    private static func put(_ session: String, html: String?, allowed: Bool = true, savedAt: Double? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = ["sessionId": .string(session), "v": .number(1), "width": .number(800)]
        if let html { params["html"] = .string(html) }
        if let savedAt { params["savedAt"] = .number(savedAt) }
        return try await AgentPaneTailCache.shared.snapshots.reply("chat.snapshot.put", params: .object(params), op: "cmux.agent.chat.snapshot.put",
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
        // Only the page's own document runs it: a cross-origin frame in the page can't load it.
        #expect(answer.headers["Cross-Origin-Resource-Policy"] == "same-origin")
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
            // Then the page's boot, as the script loads async and may come after it (chatSnapshot/boot.ts).
            #expect(script.hasSuffix(";self.__cmuxChatSnapshotTheme=\"theme-1\";self.__cmuxChatSnapshotBoot?.();"))
            session = nil
            #expect(await Self.served(resources) == "self.__cmuxChatSnapshot=null;self.__cmuxChatSnapshotWhy=\"no-chat\";self.__cmuxChatSnapshotTheme=\"theme-1\";self.__cmuxChatSnapshotBoot?.();")
            session = "other"
            #expect(await Self.served(resources) == "self.__cmuxChatSnapshot=null;self.__cmuxChatSnapshotWhy=\"none\";self.__cmuxChatSnapshotTheme=\"theme-1\";self.__cmuxChatSnapshotBoot?.();")
        }
    }

    /// Once the copy read ahead is in, the document's request is answered in the turn it arrives,
    /// with what the usual answer gives; before, and for an incognito page, as the usual answer says.
    @Test func theCopyReadAheadAnswersAtOnce() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-7", html: "<main>ready</main>")
            await disk.settled()
            let url = URL(string: "cmux-page://cmux.agent/__snapshot/chat.js")!
            let request = PageResourceRequest(prefix: "__snapshot", path: ["chat.js"], url: url)
            let resources = AgentPageResources(session: { "s-7" }, allowed: { true })
            resources.themeKey = { "theme-1" }
            #expect(resources.readyResource(for: request) == nil, "answered before the read was in")
            await resources.readAhead()
            let ready = try #require(resources.readyResource(for: request))
            #expect(ready.mimeType == "text/javascript")
            let script = try #require(String(data: ready.data, encoding: .utf8))
            #expect(script.contains("<main>ready</main>"))
            #expect(script.hasSuffix(";self.__cmuxChatSnapshotTheme=\"theme-1\";self.__cmuxChatSnapshotBoot?.();"))
            // Taken once: a reload asks the usual way and reads the copy as it is then.
            #expect(resources.readyResource(for: request) == nil)
            // A page in an incognito window gets its null at once, with no copy.
            let incognito = AgentPageResources(session: { "s-7" }, allowed: { false })
            let refused = try #require(incognito.readyResource(for: request))
            #expect(String(data: refused.data, encoding: .utf8)?.hasPrefix("self.__cmuxChatSnapshot=null;") == true)
        }
    }

    /// A request that took the read ahead before it was in leaves no copy behind: a later request
    /// (a reload) reads the chat's copy as it is then, never the one read when the page was made.
    @Test func aReadAheadTakenBeforeItIsInIsNotKept() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-9", html: "<main>first</main>")
            await disk.settled()
            let url = URL(string: "cmux-page://cmux.agent/__snapshot/chat.js")!
            let request = PageResourceRequest(prefix: "__snapshot", path: ["chat.js"], url: url)
            let resources = AgentPageResources(session: { "s-9" }, allowed: { true })
            let first = try #require(await Self.served(resources))
            #expect(first.contains("<main>first</main>"))
            await resources.readAhead()
            #expect(resources.readyResource(for: request) == nil, "the consumed read ahead was kept")
            try await Self.put("s-9", html: "<main>second</main>")
            await disk.settled()
            let reload = try #require(await Self.served(resources))
            #expect(reload.contains("<main>second</main>"))
            #expect(!reload.contains("<main>first</main>"))
        }
    }

    /// Two pages of one chat: a copy captured before the one kept is dropped, whichever arrives last.
    @Test func anOlderCaptureNeverReplacesANewerOne() async throws {
        try await Self.withDisk { disk in
            let newer = try await Self.put("s-10", html: "<main>newer</main>", savedAt: 2_000)
            #expect(newer["kept"] == .bool(true))
            let older = try await Self.put("s-10", html: "<main>older</main>", savedAt: 1_000)
            #expect(older["kept"] == .bool(false))
            await disk.settled()
            #expect(try await Self.get("s-10")["html"]?.stringValue == "<main>newer</main>")
            try await Self.put("s-10", html: "<main>newest</main>", savedAt: 3_000)
            await disk.settled()
            #expect(try await Self.get("s-10")["html"]?.stringValue == "<main>newest</main>")
        }
    }

    /// A forgotten chat (purged) stays forgotten: a copy captured before the forget and arriving
    /// after it is not kept, and a copy captured after it is.
    @Test func aCopyCapturedBeforeAForgetIsNotKept() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-11", html: "<main>shown</main>", savedAt: 1_000)
            try await Self.put("s-11", html: nil, savedAt: 3_000)
            let late = try await Self.put("s-11", html: "<main>purged</main>", savedAt: 2_000)
            #expect(late["kept"] == .bool(false))
            await disk.settled()
            #expect(try await Self.get("s-11") == .null)
            #expect(await disk.read("s-11") == nil)
            try await Self.put("s-11", html: "<main>after</main>", savedAt: 4_000)
            await disk.settled()
            #expect(try await Self.get("s-11")["html"]?.stringValue == "<main>after</main>")
        }
    }

    /// A copy read ahead before a sign-out is never served after it, at once or the usual way, and
    /// the store's copies on disk are gone.
    @Test func aCopyReadAheadIsNotServedAfterSignOut() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-8", html: "<main>before sign-out</main>")
            await disk.settled()
            let url = URL(string: "cmux-page://cmux.agent/__snapshot/chat.js")!
            let request = PageResourceRequest(prefix: "__snapshot", path: ["chat.js"], url: url)
            let ready = AgentPageResources(session: { "s-8" }, allowed: { true })
            let usual = AgentPageResources(session: { "s-8" }, allowed: { true })
            await ready.readAhead()
            await usual.readAhead()
            AgentPaneTailCache.shared.clear()
            await disk.settled()
            #expect(await disk.read("s-8") == nil)
            let answer = try #require(ready.readyResource(for: request))
            let script = try #require(String(data: answer.data, encoding: .utf8))
            #expect(script.hasPrefix("self.__cmuxChatSnapshot=null;"))
            #expect(!script.contains("before sign-out"))
            // A new lifecycle after the sign-out does not bring the old copy back.
            AgentPaneTailCache.shared.resume()
            let served = try #require(await Self.served(usual))
            #expect(served.hasPrefix("self.__cmuxChatSnapshot=null;"))
            #expect(!served.contains("before sign-out"))
        }
    }

    /// An incognito chat's page is never kept and never served, also when a page outside incognito
    /// kept a copy of the same chat, and also with that copy read ahead when the page was made.
    /// The pane takes a page whose window it does not know yet as incognito (AgentPaneView).
    @Test func anIncognitoChatKeepsNothing() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-3", html: "<main>secret</main>", allowed: false)
            await disk.settled()
            #expect(await disk.read("s-3") == nil)
            try await Self.put("s-3", html: "<main>shown</main>")
            await disk.settled()
            #expect(try await Self.get("s-3", allowed: false) == .null)
            let resources = AgentPageResources(session: { "s-3" }, allowed: { false })
            #expect(await Self.served(resources) == "self.__cmuxChatSnapshot=null;self.__cmuxChatSnapshotWhy=\"not-kept-here\";self.__cmuxChatSnapshotTheme=\"\";self.__cmuxChatSnapshotBoot?.();")
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

    /// A page that could not keep its copy (too large, no chat drawn) says why: the next document's
    /// record reads it, and nothing is drawn or returned.
    @Test func aWriteWithoutACopyKeepsWhy() async throws {
        try await Self.withDisk { disk in
            try await Self.put("s-6", html: "<main>a</main>")
            _ = try await AgentPaneTailCache.shared.snapshots.reply("chat.snapshot.put",
                                                              params: .object(["sessionId": .string("s-6"), "miss": .string("too large")]),
                                                              op: "cmux.agent.chat.snapshot.put", allowed: true,
                                                              pageGeneration: AgentPaneTailCache.shared.generation)
            await disk.settled()
            #expect(try await Self.get("s-6") == .null)
            let resources = AgentPageResources(session: { "s-6" }, allowed: { true })
            #expect(await Self.served(resources) == "self.__cmuxChatSnapshot=null;self.__cmuxChatSnapshotWhy=\"none: too large\";self.__cmuxChatSnapshotTheme=\"\";self.__cmuxChatSnapshotBoot?.();")
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
