import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

/// cx-z5vd: a new chat's typed text, from before it has an acpmux session, comes back after a
/// relaunch. The page's `chat.unsentDraft` reaches the tab's kept drafts on disk, and the next run
/// opens that tab as the chat with the text as its draft (not as the New Tab page). Once the chat
/// has a session, acpmux keeps its draft and the tab's copy is gone.
@MainActor
struct UnsentDraftTests {
    static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params])
    }

    @Test func aNewChatsTypedTextComesBackAfterARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()

        // This run's drafts, held as the tab store holds them.
        let drafts = AgentUnsentDrafts(file: file, files: files)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "compare the two retry policies"]))

        // The next run's tab, still without a session, opens as the chat with its draft.
        let relaunched = AgentUnsentDrafts(file: file, files: files)
        let seed = try #require(relaunched.seed(for: "tab-1", session: nil))
        #expect(await seed.take()?.draft == "compare the two retry policies")
        #expect(relaunched.seed(for: "tab-1", session: "s-1") == nil, "a chat with a session keeps its draft in acpmux")
        #expect(relaunched.seed(for: "tab-2", session: nil) == nil)

        // The first prompt starts the chat's session: the tab's copy goes, and later text is acpmux's.
        _ = await model.respond(to: Self.request("chat.persistSession", ["sessionId": "s-1"]))
        #expect(AgentUnsentDrafts(file: file, files: files).seed(for: "tab-1", session: nil) == nil)
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "later"]))
        #expect(AgentUnsentDrafts(file: file, files: files).seed(for: "tab-1", session: nil) == nil)
        withExtendedLifetime(drafts) {}
    }

    @Test func aMultiMegabyteDraftComesBackAfterARelaunch() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()
        let large = String(repeating: "x", count: 2 * 1024 * 1024)
        AgentUnsentDrafts(file: file, files: files).set(large, for: "tab-large")
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-large") == large)
    }

    /// cmux#32276: a new chat whose tab opens another chat leaves its text (typed, and prompts held
    /// for a trust answer) in its window's one slot, on disk: a second leftover adds to it, the
    /// window's next new chat takes it once, and nothing sends it.
    @Test func aNewChatsTextLeftWhenItsTabOpensAnotherChatWaitsForTheWindowsNextNewChat() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()
        let drafts = AgentUnsentDrafts(file: file, files: files)
        drafts.windowOfTab = { $0 == "tab-1" || $0 == "tab-2" ? "window-1" : nil }
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "typed here"]))
        _ = await model.respond(to: Self.request("chat.leftover", ["text": "held prompt\n\ntyped here"]))
        // The tab opens chat B: its own copy goes, the window's slot stays.
        _ = await model.respond(to: Self.request("chat.persistSession", ["sessionId": "s-b"]))
        // A chat with a session leaves nothing.
        _ = await model.respond(to: Self.request("chat.leftover", ["text": "not a new chat's"]))
        // Another new chat of the same window leaves its own: it adds to the first.
        let other = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(other) { "tab-2" }
        _ = await other.respond(to: Self.request("chat.leftover", ["text": "second"]))

        // After a quit: the window's next New Tab page gets both; no other window has any.
        let relaunched = AgentUnsentDrafts(file: file, files: files)
        #expect(relaunched.seed(for: "tab-1", session: nil) == nil, "the left text is no tab's draft")
        #expect(relaunched.leftover(inWindow: "window-2") == nil)
        #expect(relaunched.leftover(inWindow: "window-1") == "held prompt\n\ntyped here\n\nsecond")
        // A page that never shows (its tab failed to open) gives nothing up: the next page gets it.
        #expect(relaunched.leftover(inWindow: "window-1") == "held prompt\n\ntyped here\n\nsecond")
        // A page reports it showed the first part; what was left after it was read stays. Another
        // window's slot with the same text is never its to give up.
        relaunched.leave("second", inWindow: "window-2")
        let page = AgentPaneModel(host: MockAgentPaneHost())
        relaunched.windowOfTab = { $0 == "tab-5" ? "window-2" : "window-1" }
        relaunched.wire(page) { "tab-3" }
        #expect(page.newTabForPage == nil, "only a New Tab page gets it")
        // A New Tab page its host gave none (a workspace's first page, a restored one) reads its window's.
        let first = AgentPaneModel(host: MockAgentPaneHost(), newTab: AgentPaneNewTab(kind: .agent))
        relaunched.wire(first) { "tab-4" }
        #expect(first.newTabForPage?.draft == "held prompt\n\ntyped here\n\nsecond")
        _ = await page.respond(to: Self.request("chat.leftoverTaken", ["text": "held prompt\n\ntyped here"]))
        #expect(relaunched.leftover(inWindow: "window-1") == "second")
        _ = await page.respond(to: Self.request("chat.leftoverTaken", ["text": "second"]))
        #expect(relaunched.leftover(inWindow: "window-1") == nil, "a leftover seeds one new chat")
        #expect(relaunched.leftover(inWindow: "window-2") == "second", "window 2's slot is its own")
        #expect(AgentUnsentDrafts(file: file, files: files).leftover(inWindow: "window-1") == nil)
        let elsewhere = AgentPaneModel(host: MockAgentPaneHost())
        relaunched.wire(elsewhere) { "tab-5" }
        _ = await elsewhere.respond(to: Self.request("chat.leftoverTaken", ["text": "second"]))
        #expect(relaunched.leftover(inWindow: "window-2") == nil)
        withExtendedLifetime(relaunched) {}
        withExtendedLifetime(drafts) {}
    }

    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unsent-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A relaunch: the page's text before it is handed the tab's kept draft (its empty editor, or
    /// what the person typed while it loaded) never replaces that draft; once handed it, the page's
    /// clear still clears.
    @Test func aKeptDraftSurvivesTheLoadAndAClearStillClears() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()
        AgentUnsentDrafts(file: file, files: files).set("the saved draft", for: "tab-1")

        let drafts = AgentUnsentDrafts(file: file, files: files)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        // (c) The page's empty text before it has the draft is no clear.
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": ""]))
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == "the saved draft")
        // (a, b) Text typed before the draft reached the page joins it, after it.
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "typed while loading"]))
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == "the saved draft\n\ntyped while loading")
        // The page still has not taken the draft: its next text is still only its typing, merged with
        // the kept draft, never in place of it (cmux#28204 review at 027ee470: "x" then "xy" left "xy").
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "typed while loading, more"]))
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == "the saved draft\n\ntyped while loading, more")
        // Deleting its typing leaves the kept draft, which the page never had.
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": ""]))
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == "the saved draft")
        // (d) Once the page takes it (its seed), the page's text is the draft: deleting it clears it.
        let seed = try #require(drafts.seed(for: "tab-1", session: nil))
        _ = await seed.take()
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": ""]))
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == nil)
        withExtendedLifetime(drafts) {}
    }

    /// (c, d) Once the page was handed the draft (the tab's seed), an empty text is the person's clear.
    @Test func aClearAfterTheSeedClears() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()
        AgentUnsentDrafts(file: file, files: files).set("the saved draft", for: "tab-1")

        let drafts = AgentUnsentDrafts(file: file, files: files)
        let seed = try #require(drafts.seed(for: "tab-1", session: nil))
        #expect(await seed.take()?.draft == "the saved draft")
        drafts.typed("the saved draft, edited", for: "tab-1")
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == "the saved draft, edited")
        drafts.typed("", for: "tab-1")
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == nil)
        // A send starts the chat's session: the tab's copy goes (acpmux keeps the chat's draft).
        drafts.typed("next", for: "tab-1")
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        _ = await model.respond(to: Self.request("chat.persistSession", ["sessionId": "s-1"]))
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == nil)
    }

    /// A seed made but never taken (the host failed before its handshake, and a stand-in page mounted
    /// without the draft) leaves the draft waiting: that page's empty text does not clear it, and the
    /// next host gets it. Taken, the page's clear clears it.
    @Test func aSeedNeverTakenKeepsTheDraftForTheNextHost() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()
        AgentUnsentDrafts(file: file, files: files).set("the saved draft", for: "tab-1")

        let drafts = AgentUnsentDrafts(file: file, files: files)
        _ = try #require(drafts.seed(for: "tab-1", session: nil))
        drafts.typed("", for: "tab-1")
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == "the saved draft")
        let retry = try #require(drafts.seed(for: "tab-1", session: nil))
        #expect(await retry.take()?.draft == "the saved draft")
        drafts.typed("", for: "tab-1")
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == nil)
    }

    /// A file this run cannot read is set aside, never replaced by an empty or partial one.
    @Test func anUnreadableFileIsSetAsideNotOverwritten() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()
        let corrupt = Data("{\"tab-1\": \"half a dra".utf8)
        try corrupt.write(to: file)

        let drafts = AgentUnsentDrafts(file: file, files: files)
        // Nothing written yet: the file is as it was.
        drafts.typed("", for: "tab-2")
        #expect(try Data(contentsOf: file) == corrupt)
        drafts.typed("new text", for: "tab-2")
        // A fresh store reads after the queued save (AgentPaneStateFile), so the move has run too.
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-2") == "new text")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try #require(names.first { $0.contains("unreadable") })
        #expect(try Data(contentsOf: directory.appending(path: aside)) == corrupt)
    }

    /// A file that could not be read when the store loaded is set aside even when it reads by the
    /// first save (a read that failed once): the store never loaded its drafts, so it never writes
    /// over them.
    @Test func aFileUnreadableAtLoadIsSetAsideEvenWhenItReadsLater() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()
        try Data("{\"tab-1\": \"half a dra".utf8).write(to: file)

        let drafts = AgentUnsentDrafts(file: file, files: files)
        let readable = Data("{\"tab-1\":\"kept draft\"}".utf8)
        try readable.write(to: file)
        drafts.typed("new text", for: "tab-2")
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-2") == "new text")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try #require(names.first { $0.contains("unreadable") })
        #expect(try Data(contentsOf: directory.appending(path: aside)) == readable)
    }

    /// A draft larger than the former limit is retained and merged without loss.
    @Test func aLargeTypedMergeKeepsTheSavedDraft() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName), files = AgentPaneStateFiles()
        let saved = String(repeating: "s", count: 2 * 1024 * 1024)
        AgentUnsentDrafts(file: file, files: files).set(saved, for: "tab-1")

        let drafts = AgentUnsentDrafts(file: file, files: files)
        drafts.typed("x", for: "tab-1")
        #expect(drafts.draft(for: "tab-1") == saved + "\n\nx")
        #expect(AgentUnsentDrafts(file: file, files: files).draft(for: "tab-1") == saved + "\n\nx")
    }

    /// The merge keeps both texts once, and leaves a text that already holds the other as it is.
    @Test func theMergeKeepsBothOnce() {
        #expect(AgentUnsentDrafts.merged(typed: "b", kept: "a") == "a\n\nb")
        #expect(AgentUnsentDrafts.merged(typed: "a", kept: "a") == "a")
        #expect(AgentUnsentDrafts.merged(typed: "a\n\nb", kept: "a") == "a\n\nb")
        // Never by substring: both drafts stay.
        #expect(AgentUnsentDrafts.merged(typed: "debugging", kept: "bug") == "bug\n\ndebugging")
        #expect(AgentUnsentDrafts.merged(typed: "a and more", kept: "a") == "a\n\na and more")
        #expect(AgentUnsentDrafts.merged(typed: "b", kept: "a\n\nb") == "a\n\nb")
    }
}
