import CmuxNextAgentPane
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor
struct UnsentDraftGenerationTests {
    @Test func aVersionedClearSurvivesRelaunchAndRejectsLateText() async throws {
        let directory = try UnsentDraftTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let drafts = AgentUnsentDrafts(file: file)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab" }
        _ = await model.respond(to: UnsentDraftTests.request("chat.unsentDraft", ["text": "old", "generation": 4]))
        _ = await model.respond(to: UnsentDraftTests.request("chat.unsentDraft", ["text": "", "generation": 5]))
        _ = await model.respond(to: UnsentDraftTests.request("chat.unsentDraft", ["text": "late", "generation": 4]))
        #expect(drafts.draft(for: "tab") == nil)
        #expect(drafts.generation(for: "tab") == 5)

        let relaunched = AgentUnsentDrafts(file: file)
        #expect(!relaunched.hasDraft("tab"))
        relaunched.typed("legacy late", for: "tab")
        relaunched.set("versioned late", for: "tab", generation: 4)
        #expect(relaunched.draft(for: "tab") == nil)
        let source = try #require(relaunched.seed(for: "tab", session: nil))
        let seed = await source.take()
        #expect(seed?.draft == "")
        #expect(seed?.draftGeneration == 5)
        relaunched.typed("next prompt", for: "tab", generation: 5)
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab") == "next prompt")
        #expect(AgentUnsentDrafts(file: file).generation(for: "tab") == 5)
    }

    @Test func aNewerReplacementBeforeHandoffNeverMergesOldText() throws {
        let directory = try UnsentDraftTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        AgentUnsentDrafts(file: file).set("old text", for: "tab", generation: 3)
        let drafts = AgentUnsentDrafts(file: file)
        drafts.typed("pasted replacement", for: "tab", generation: 4)
        drafts.typed("stale callback", for: "tab", generation: 3)
        #expect(drafts.handOut("tab") == "pasted replacement")
        #expect(drafts.generation(for: "tab") == 4)
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab") == "pasted replacement")
    }

    @Test func equalGenerationsStillMergeBeforeHandoff() throws {
        let directory = try UnsentDraftTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        AgentUnsentDrafts(file: file).set("saved", for: "tab", generation: 4)
        let drafts = AgentUnsentDrafts(file: file)
        drafts.typed("", for: "tab", generation: 4)
        #expect(drafts.draft(for: "tab") == "saved")
        drafts.typed("typed", for: "tab", generation: 4)
        #expect(drafts.draft(for: "tab") == "saved\n\ntyped")
        #expect(drafts.generation(for: "tab") == 4)
    }

    @Test func sendAdvancesTheBoundaryEvenWithoutASettledDraft() async throws {
        let directory = try UnsentDraftTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let drafts = AgentUnsentDrafts(file: file)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab" }
        _ = await model.respond(to: UnsentDraftTests.request("chat.persistSession", ["sessionId": "s-1"]))
        let relaunched = AgentUnsentDrafts(file: file)
        #expect(relaunched.generation(for: "tab") == 1)
        relaunched.typed("sent text", for: "tab", generation: 0)
        #expect(relaunched.draft(for: "tab") == nil)
    }

    @Test func nativeClearAndMoveLeaveDurableBoundaries() throws {
        let directory = try UnsentDraftTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let drafts = AgentUnsentDrafts(file: file)
        drafts.set("sent", for: "tab", generation: 8)
        drafts.set("", for: "tab")
        drafts.set("late", for: "tab", generation: 8)
        drafts.set("new draft", for: "provisional", generation: 2)
        drafts.move("provisional", to: "real")
        let relaunched = AgentUnsentDrafts(file: file)
        relaunched.typed("late provisional", for: "provisional", generation: 2)
        #expect(relaunched.generation(for: "tab") == 9)
        #expect(relaunched.draft(for: "tab") == nil)
        #expect(relaunched.draft(for: "provisional") == nil)
        #expect(relaunched.draft(for: "real") == "new draft")
        #expect(relaunched.generation(for: "real") == 2)
    }

    @Test func legacyFilesAndRequestsStartAtZero() async throws {
        let directory = try UnsentDraftTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        try JSONEncoder().encode(["tab": "legacy text"]).write(to: file)
        let drafts = AgentUnsentDrafts(file: file)
        let seed = await drafts.seed(for: "tab", session: nil)?.take()
        #expect(seed?.draft == "legacy text")
        #expect(seed?.draftGeneration == 0)
        let model = AgentPaneModel(host: MockAgentPaneHost())
        drafts.wire(model) { "tab" }
        _ = await model.respond(to: UnsentDraftTests.request("chat.unsentDraft", ["text": "legacy edit"]))
        #expect(AgentUnsentDrafts(file: file).draft(for: "tab") == "legacy edit")
        #expect(AgentUnsentDrafts(file: file).generation(for: "tab") == 0)
    }

    @Test func handshakeIncludesAnEmptyTombstonesGeneration() async throws {
        let drafts = AgentUnsentDrafts(file: nil)
        drafts.set("", for: "tab", generation: 5)
        let model = AgentPaneModel(host: MockAgentPaneHost(), seed: drafts.seed(for: "tab", session: nil))
        let reply = await model.respond(to: .ready)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["draft"] as? String == "")
        #expect(value["draftGeneration"] as? Int == 5)
    }

    @Test func bridgeRejectsMalformedGenerations() {
        let invalid: [Any] = [-1, 1.5, true, "2", NSNull(), 9_007_199_254_740_992]
        for generation in invalid {
            let request = UnsentDraftTests.request("chat.unsentDraft", ["text": "text", "generation": generation])
            #expect(request == .unsupported("chat.unsentDraft"))
        }
        #expect(UnsentDraftTests.request("chat.unsentDraft", ["text": "text", "generation": 9_007_199_254_740_991])
                == .unsentDraft("text", generation: 9_007_199_254_740_991))
    }

    @Test func malformedStoredGenerationIsPreservedBeforeWriting() throws {
        let directory = try UnsentDraftTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: AgentUnsentDrafts.fileName)
        let corrupt = Data(#"{"tab":{"text":"kept","generation":-1}}"#.utf8)
        try corrupt.write(to: file)
        let drafts = AgentUnsentDrafts(file: file)
        drafts.typed("new", for: "other", generation: 1)
        #expect(AgentUnsentDrafts(file: file).draft(for: "other") == "new")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let aside = try #require(names.first { $0.contains("unreadable") })
        #expect(try Data(contentsOf: directory.appending(path: aside)) == corrupt)
    }
}
