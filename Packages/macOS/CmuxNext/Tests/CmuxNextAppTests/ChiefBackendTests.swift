import AppKit
import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// UniiChat as an official Chief backend next to Claude and Codex: the shared backend list and
/// its names, the Chief Settings harness picker's items, the New Chief sheet's choice, and the
/// local create path that hands `harness: "unii"` to this Mac's Chief owner.
@Suite struct ChiefBackendTests {
    @Test func theOfficialBackendsAreClaudeCodexAndUniiChatInThatOrder() {
        #expect(ChiefBackend.official.map(\.id) == ["claude", "codex", "muse", "unii"])
        #expect(ChiefBackend.official.filter(\.isDefault) == [.claude])
        // Claude stays on the cloud path; UniiChat's sign-in is this Mac's, so its Chiefs are too.
        #expect(!ChiefBackend.claude.createsOnThisMac)
        #expect(ChiefBackend.unii.createsOnThisMac)
        #expect(ChiefBackend.codex.createsOnThisMac)
        #expect(ChiefBackend.muse.createsOnThisMac)
    }

    /// An id that is not an official engine reads as a name, never as the raw id (#89).
    @Test func titlesNameEachBackendAndShowAnUnknownIdByName() {
        #expect(ChiefBackend.title(for: "claude") == ChiefBackend.claude.title)
        #expect(ChiefBackend.title(for: "unii") == ChiefBackend.unii.title)
        #expect(!ChiefBackend.unii.title.isEmpty && ChiefBackend.unii.title != "unii")
        #expect(ChiefBackend.title(for: "claude-cr") == "\(ChiefBackend.claude.title) (CodeRouter)")
        #expect(ChiefBackend.title(for: "gemini") == "Gemini CLI")
        #expect(ChiefBackend(id: "unii") == .unii)
        #expect(ChiefBackend(id: "claude-sr") == nil)
        #expect(ChiefBackend.unii.hint != nil)
        #expect(ChiefBackend(id: "muse") == .muse)
        #expect(ChiefBackend.title(for: "muse") == ChiefBackend.muse.title && ChiefBackend.muse.title != "muse")
        #expect(ChiefBackend.muse.hint != nil)
        #expect(ChiefBackend.claude.hint == nil)
    }

    @Test func onlyAChiefOffTheDefaultEngineGetsABadge() {
        #expect(ChiefBackend.badge(for: "unii") == ChiefBackend.unii.title)
        #expect(ChiefBackend.badge(for: "codex") == ChiefBackend.codex.title)
        #expect(ChiefBackend.badge(for: "muse") == ChiefBackend.muse.title)
        #expect(ChiefBackend.badge(for: "gemini") == "Gemini CLI")
        for harness in [nil, "", "default", "claude", "claude-cr", "claude-sr"] as [String?] {
            #expect(ChiefBackend.badge(for: harness) == nil, "\(String(describing: harness))")
        }
    }

    @MainActor @Test func theHarnessPickerOffersUniiChatWithAndWithoutTheCodeRouterRoute() {
        #expect(HomeChiefSettingsView.harnesses(routeConfigured: false) == ["claude", "codex", "muse", "unii"])
        #expect(HomeChiefSettingsView.harnesses(routeConfigured: true) == ["claude", "claude-cr", "codex", "muse", "unii"])
        let items = HomeChiefSettingsView.harnessItems(routeConfigured: true)
        #expect(items.first { $0.value == "unii" }?.title == ChiefBackend.unii.title)
        // The route reads as a name, not its id (#89).
        #expect(items.first { $0.value == "claude-cr" }?.title == "\(ChiefBackend.claude.title) (CodeRouter)")
    }

    /// Lawrence 2026-10-23: "chief can choose between literally all the acpmux stuff". After the
    /// official engines, the picker offers every harness this Mac's acpmux lists, once each.
    @MainActor @Test func theHarnessPickerOffersEveryAcpmuxHarness() {
        let listed = ["claude", "codex", "opencode", "pi", "gemini", "claude-sr", "claude-cr", "muse", "unii"]
        #expect(HomeChiefSettingsView.harnesses(routeConfigured: false, listed: listed)
            == ["claude", "codex", "muse", "unii", "opencode", "pi", "gemini", "claude-sr", "claude-cr"])
        #expect(HomeChiefSettingsView.harnesses(routeConfigured: true, listed: listed)
            == ["claude", "claude-cr", "codex", "muse", "unii", "opencode", "pi", "gemini", "claude-sr"])
        let items = HomeChiefSettingsView.harnessItems(routeConfigured: false, listed: ["gemini"])
        #expect(items.last?.value == "gemini" && items.last?.title == "Gemini CLI")
    }

    @MainActor @Test func theNewChiefSheetHandsTheChosenBackendToItsCreate() async throws {
        let sheet = HomeNewChiefSheet()
        _ = sheet.view
        #expect(sheet.chosenBackend == .claude)
        #expect(sheet.backendHint.isHidden)
        let (asked, ask) = AsyncStream<(String, ChiefBackend)>.makeStream()
        sheet.onCreate = { name, backend in
            ask.yield((name, backend))
            return .offline
        }
        sheet.name.stringValue = "  Scout "
        let index = try #require(sheet.backend.itemArray.firstIndex { $0.representedObject as? String == "unii" })
        sheet.backend.selectItem(at: index)
        #expect(sheet.chosenBackend == .unii)
        sheet.submit()
        var iterator = asked.makeAsyncIterator()
        let request = try #require(await iterator.next())
        #expect(request.0 == "Scout")
        #expect(request.1 == .unii)
    }

    @Test func aUniiChatChiefIsMadeOnTheLocalOwnerWithHarnessUnii() async throws {
        let calls = Calls()
        let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")
        let creator = HomeLocalChiefCreator(me: me, send: { operation, params, key in
            await calls.sent(operation, params, key)
            return .object(["value": .object(["id": .string("agent_scout01"), "display_name": .string("Scout")]),
                            "replayed": .bool(false)])
        }, open: { request in
            await calls.opened(request)
            return "conv_scout"
        })
        let made = try await creator.create(name: "Scout", backend: .unii)
        #expect(made.chief == "agent_scout01")
        #expect(made.conversation == ConversationID("conv_scout"))
        let sent = try #require(await calls.sends.first)
        #expect(sent.operation == "chief.profile.create")
        #expect(sent.params["harness"] == .string("unii"))
        #expect(sent.params["display_name"] == .string("Scout"))
        #expect(!sent.key.isEmpty)
        let dm = try #require(await calls.opens.first)
        #expect(dm.participants.map(\.id) == ["user_local", "agent_scout01"])
        #expect(dm.participants.last?.kind == .agent)
        #expect(dm.participants.last?.agentClass == "mux")
        #expect(dm.idempotencyKey != sent.key)
    }

    @Test func theDefaultEngineIsNotNamedInALocalCreate() {
        #expect(HomeLocalChiefCreator.params(name: "A", backend: .claude) == ["display_name": .string("A")])
        #expect(HomeLocalChiefCreator.params(name: "A", backend: .codex)["harness"] == .string("codex"))
    }

    @Test func aRefusedLocalCreateOpensNoConversation() async {
        let calls = Calls()
        let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")
        let creator = HomeLocalChiefCreator(me: me, send: { _, _, _ in
            throw DaemonError.command(cmd: "chief.profile.create", message: "acpmux has no harness unii", code: "operation.failed")
        }, open: { request in
            await calls.opened(request)
            return "never"
        })
        await #expect(throws: DaemonError.self) { try await creator.create(name: "Scout", backend: .unii) }
        #expect(await calls.opens.isEmpty)
    }

    @Test func aChiefsBadgeEngineIsItsSavedChoiceElseItsRecordsEngine() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-harness-\(UUID().uuidString)", isDirectory: true)
        // The default Chief saved codex; agent_scout01 saved nothing, so its record's unii counts.
        let saved = home.appendingPathComponent("optchat", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try Data(#"{"harness":"codex"}"#.utf8).write(to: saved.appendingPathComponent("engine.json"))
        let listed: JSONValue = .object(["chiefs": .array([
            .object(["id": .string("agent_scout01"), "engine": .object(["harness": .string("unii")])]),
            .object(["id": .string("agent_mux"), "engine": .object([:])]),
        ])])
        let reader = HomeChiefHarnesses(muxHome: home, list: { listed })
        let harnesses = await reader.read(chiefs: ["agent_mux", "agent_scout01", "agent_plain01"])
        #expect(harnesses == ["agent_mux": "codex", "agent_scout01": "unii"])
        #expect(HomeChiefHarnesses.recordHarnesses(nil).isEmpty)
    }

    /// Delete Chief on one of this Mac's Chiefs: the same `chief.profile.list` read names the deleted
    /// ids (Home hides their conversations); an owner that does not list them, or an unread list,
    /// changes nothing (nil keeps the ids known).
    @Test func theOwnersListNamesThisMacsDeletedChiefs() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-chief-deleted-\(UUID().uuidString)", isDirectory: true)
        let listed: JSONValue = .object(["chiefs": .array([.object(["id": .string("agent_mux")])]),
                                         "deleted": .array([.string("agent_gone01")])])
        let read = await HomeChiefHarnesses(muxHome: home, list: { listed }).readWithDeleted(chiefs: ["agent_mux", "agent_gone01"])
        #expect(read.deleted == ["agent_gone01"])
        let older = await HomeChiefHarnesses(muxHome: home, list: { .object(["chiefs": .array([])]) }).readWithDeleted(chiefs: [])
        #expect(older.deleted == nil)
        let unread = await HomeChiefHarnesses(muxHome: home, list: { nil }).readWithDeleted(chiefs: [])
        #expect(unread.deleted == nil)
    }
}

/// What the fake owner calls received.
private actor Calls {
    var sends: [(operation: String, params: [String: JSONValue], key: String)] = []
    var opens: [CreateConversationRequest] = []

    func sent(_ operation: String, _ params: [String: JSONValue], _ key: String) { sends.append((operation, params, key)) }
    func opened(_ request: CreateConversationRequest) { opens.append(request) }
}
