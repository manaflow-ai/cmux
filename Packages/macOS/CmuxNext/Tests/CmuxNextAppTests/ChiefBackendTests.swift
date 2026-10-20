import AppKit
import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextApp
import Foundation
import Testing

/// UniiChat as an official Chief backend next to Claude and Codex: the shared backend list and
/// its names, the Chief Settings harness picker's items, the New Chief sheet's choice, and the
/// local create path that hands `harness: "unii"` to this Mac's Chief owner.
@Suite struct ChiefBackendTests {
    @Test func theOfficialBackendsAreClaudeCodexAndUniiChatInThatOrder() {
        #expect(ChiefBackend.official.map(\.id) == ["claude", "codex", "unii"])
        #expect(ChiefBackend.official.filter(\.isDefault) == [.claude])
    }

    @Test func titlesNameEachBackendAndShowAnUnknownIdAsItIs() {
        #expect(ChiefBackend.title(for: "claude") == ChiefBackend.claude.title)
        #expect(ChiefBackend.title(for: "unii") == ChiefBackend.unii.title)
        #expect(!ChiefBackend.unii.title.isEmpty && ChiefBackend.unii.title != "unii")
        #expect(ChiefBackend.title(for: "claude-cr") == "claude-cr")
        #expect(ChiefBackend.title(for: "gemini") == "gemini")
        #expect(ChiefBackend(id: "unii") == .unii)
        #expect(ChiefBackend(id: "claude-sr") == nil)
        #expect(ChiefBackend.unii.hint != nil)
        #expect(ChiefBackend.claude.hint == nil)
    }

    @Test func onlyAChiefOffTheDefaultEngineGetsABadge() {
        #expect(ChiefBackend.badge(for: "unii") == ChiefBackend.unii.title)
        #expect(ChiefBackend.badge(for: "codex") == ChiefBackend.codex.title)
        #expect(ChiefBackend.badge(for: "gemini") == "gemini")
        for harness in [nil, "", "default", "claude", "claude-cr", "claude-sr"] as [String?] {
            #expect(ChiefBackend.badge(for: harness) == nil, "\(String(describing: harness))")
        }
    }

    @MainActor @Test func theHarnessPickerOffersUniiChatWithAndWithoutTheCodeRouterRoute() {
        #expect(HomeChiefSettingsView.harnesses(routeConfigured: false) == ["claude", "codex", "unii"])
        #expect(HomeChiefSettingsView.harnesses(routeConfigured: true) == ["claude", "claude-cr", "codex", "unii"])
        let items = HomeChiefSettingsView.harnessItems(routeConfigured: true)
        #expect(items.first { $0.value == "unii" }?.title == ChiefBackend.unii.title)
        #expect(items.first { $0.value == "claude-cr" }?.title == "claude-cr")
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

    /// New Chief on the default engine (Claude) went to the signed-in account's cloud `chief.create`:
    /// signed out it answered "You're offline", while `cmux chief new` made the Chief on this Mac.
    /// Every engine's Chief is made on this Mac's Chief owner, the registry Home lists Chiefs from.
    @MainActor @Test func aNewChiefOnTheDefaultEngineIsMadeOnThisMacsChiefOwner() async throws {
        let calls = Calls()
        let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.home.localChiefCreator = {
            HomeLocalChiefCreator(me: me, send: { operation, params, key in
                await calls.sent(operation, params, key)
                return .object(["value": .object(["id": .string("agent_scout01"), "display_name": .string("Scout")])])
            }, open: { request in
                await calls.opened(request)
                return "conv_scout"
            })
        }
        let outcome = await services.home.createChief(named: "Scout")
        #expect(outcome == .opened(ConversationID("conv_scout")))
        let sent = try #require(await calls.sends.first)
        #expect(sent.operation == "chief.profile.create")
        #expect(sent.params == ["display_name": .string("Scout")])
        #expect(await calls.opens.count == 1)
        #expect(services.home.pendingSelection == ConversationID("conv_scout"))
    }

    /// Home's compose button works as classic cmux's Chief list (ChiefConversationListView, #21063):
    /// one click makes another Chief at once, named as the Chief is, with no sheet to fill first,
    /// so the person can ask it something right away. New Message stays in compose's menu.
    @MainActor @Test func homesComposeButtonStartsANewChiefInOneClick() async throws {
        let calls = Calls()
        let (opened, open) = AsyncStream<Void>.makeStream()
        let me = ConversationParticipant(id: "user_local", kind: .human, displayName: "Me")
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.home.localChiefCreator = {
            HomeLocalChiefCreator(me: me, send: { operation, params, key in
                await calls.sent(operation, params, key)
                return .object(["value": .object(["id": .string("agent_compose01"), "display_name": params["display_name"] ?? .null])])
            }, open: { request in
                await calls.opened(request)
                open.yield()
                return "conv_compose"
            })
        }
        let page = TopHomePageView(services: services, windowKey: { "compose-new-chief" })
        #expect(page.list.compose.accessibilityLabel() == HomeConversationStrings.chiefTitle)
        page.list.compose.performClick(nil)
        var iterator = opened.makeAsyncIterator()
        _ = await iterator.next()
        let sent = try #require(await calls.sends.first)
        #expect(sent.operation == "chief.profile.create")
        #expect(sent.params == ["display_name": .string(HomeStrings.chiefName)])
        #expect(await calls.opens.count == 1)
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
}

/// What the fake owner calls received.
private actor Calls {
    var sends: [(operation: String, params: [String: JSONValue], key: String)] = []
    var opens: [CreateConversationRequest] = []

    func sent(_ operation: String, _ params: [String: JSONValue], _ key: String) { sends.append((operation, params, key)) }
    func opened(_ request: CreateConversationRequest) { opens.append(request) }
}
