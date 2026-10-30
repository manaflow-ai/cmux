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
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == nil)
        _ = await model.respond(to: Self.request("chat.unsentDraft", ["text": "later"]))
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == nil)
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
        drafts.typed("next", for: "tab-1", generation: drafts.generation(for: "tab-1"))
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
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try #require(names.first { $0.contains("unreadable") })
        #expect(try Data(contentsOf: directory.appending(path: aside)) == corrupt)
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-2") == "new text")
    }

    /// A draft is never dropped for its length: a merge that passes the limit keeps the kept text
    /// and as much typed text as fits (before, the over-long merge stored nothing and deleted it).
    @Test func aMergePastTheLimitKeepsTheDraft() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        AgentUnsentDrafts(file: file).set("compare the two retry policies", for: "tab-1")

        let relaunched = AgentUnsentDrafts(file: file)
        relaunched.typed(String(repeating: "x", count: 1_000_000), for: "tab-1")
        let kept = try #require(relaunched.draft(for: "tab-1"))
        #expect(kept.hasPrefix("compare the two retry policies\n\nxxx"))
        #expect(kept.count == 1_000_000)
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab-1") == kept)

        relaunched.set(String(repeating: "y", count: 1_000_001), for: "tab-1")
        #expect(relaunched.draft(for: "tab-1")?.count == 1_000_000)
    }

    /// The merge keeps both texts once, and leaves a text that already holds the other as it is.
    @Test func theMergeKeepsBothOnce() {
        #expect(AgentUnsentDrafts.merged(typed: "b", kept: "a") == "a\n\nb")
        #expect(AgentUnsentDrafts.merged(typed: "a and more", kept: "a") == "a and more")
        #expect(AgentUnsentDrafts.merged(typed: "b", kept: "a\n\nb") == "a\n\nb")
    }

    /// The webview consumes this same fixture, including its generated million-character case.
    @Test func sharedMergeVectors() throws {
        struct Part: Decodable {
            let text: String
            let count: Int
        }
        struct Vector: Decodable {
            let name: String
            let kept: [Part]
            let typed: [Part]
            let expected: [Part]
            let typedGeneration: Int?
            let keptGeneration: Int?
        }
        func expand(_ parts: [Part]) -> String {
            parts.map { String(repeating: $0.text, count: $0.count) }.joined()
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let file = root.appending(path: "webviews/test/fixtures/composer-draft-merge.json")
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: file))
        for vector in vectors {
            let actual = AgentUnsentDrafts.merged(typed: expand(vector.typed), kept: expand(vector.kept),
                                                  typedGeneration: vector.typedGeneration ?? 0, keptGeneration: vector.keptGeneration ?? 0)
            #expect(Array(actual.utf16) == Array(expand(vector.expected).utf16), "\(vector.name)")
        }
    }

}
