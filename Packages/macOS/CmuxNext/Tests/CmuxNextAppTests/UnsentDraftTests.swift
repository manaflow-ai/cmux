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
        let file = directory.appending(path: AgentUnsentDrafts.fileName)

        // This run's drafts, held as the tab store holds them.
        let drafts = AgentUnsentDrafts(file: file)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "compare the two retry policies"]))

        // The next run's tab, still without a session, opens as the chat with its draft.
        let relaunched = AgentUnsentDrafts(file: file)
        let seed = try #require(relaunched.seed(for: "tab-1", session: nil))
        #expect(await seed.take()?.draft == "compare the two retry policies")
        #expect(relaunched.seed(for: "tab-1", session: "s-1") == nil, "a chat with a session keeps its draft in acpmux")
        #expect(relaunched.seed(for: "tab-2", session: nil) == nil)

        // The first prompt starts the chat's session: the tab's copy goes, and later text is acpmux's.
        _ = await model.respond(to: Self.request("chat.persistSession", ["sessionId": "s-1"]))
        #expect(AgentUnsentDrafts(file: file).seed(for: "tab-1", session: nil) == nil)
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "later"]))
        #expect(AgentUnsentDrafts(file: file).seed(for: "tab-1", session: nil) == nil)
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
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        AgentUnsentDrafts(file: file).set("the saved draft", for: "tab-1")

        let drafts = AgentUnsentDrafts(file: file)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        // (c) The page's empty text before it has the draft is no clear.
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": ""]))
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == "the saved draft")
        // (a, b) Text typed before the draft reached the page joins it, after it.
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "typed while loading"]))
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == "the saved draft\n\ntyped while loading")
        // (d) From then on the page's text is the draft: deleting it clears it.
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": ""]))
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == nil)
        withExtendedLifetime(drafts) {}
    }

    /// (c, d) Once the page was handed the draft (the tab's seed), an empty text is the person's clear.
    @Test func aClearAfterTheSeedClears() async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        AgentUnsentDrafts(file: file).set("the saved draft", for: "tab-1")

        let drafts = AgentUnsentDrafts(file: file)
        let seed = try #require(drafts.seed(for: "tab-1", session: nil))
        #expect(await seed.take()?.draft == "the saved draft")
        drafts.typed("the saved draft, edited", for: "tab-1")
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == "the saved draft, edited")
        drafts.typed("", for: "tab-1")
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == nil)
        // A send starts the chat's session: the tab's copy goes (acpmux keeps the chat's draft).
        drafts.typed("next", for: "tab-1")
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab-1" }
        _ = await model.respond(to: Self.request("chat.persistSession", ["sessionId": "s-1"]))
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == nil)
    }

    /// A file this run cannot read is set aside, never replaced by an empty or partial one.
    @Test func anUnreadableFileIsSetAsideNotOverwritten() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let corrupt = Data("{\"tab-1\": \"half a dra".utf8)
        try corrupt.write(to: file)

        let drafts = AgentUnsentDrafts(file: file)
        // Nothing written yet: the file is as it was.
        drafts.typed("", for: "tab-2")
        #expect(try Data(contentsOf: file) == corrupt)
        drafts.typed("new text", for: "tab-2")
        // A fresh store reads after the queued save (AgentPaneStateFile), so the move has run too.
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-2") == "new text")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try #require(names.first { $0.contains("unreadable") })
        #expect(try Data(contentsOf: directory.appending(path: aside)) == corrupt)
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
