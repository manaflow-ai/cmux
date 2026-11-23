import AppKit
import CmuxHomeCore
import CmuxNextDaemon
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
@testable import CmuxNextHomeEngine
@testable import CmuxNextApp
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

    @MainActor @Test func onItsOwnCloudMachineGoesToTheMachineStartWithOneKeyPerSheet() async throws {
        let sheet = HomeNewChiefSheet()
        _ = sheet.view
        #expect(sheet.ownMachine.isHidden)  // no machine path wired: the sheet is as it was
        let (asked, ask) = AsyncStream<(String, String)>.makeStream()
        sheet.onCreateOnMachine = { name, key in
            ask.yield((name, key))
            return .offline
        }
        sheet.onCreate = { _, _ in
            Issue.record("the hosted create ran with the machine box on")
            return .offline
        }
        #expect(!sheet.ownMachine.isHidden)
        sheet.ownMachine.state = .on
        sheet.name.stringValue = "Ops"
        sheet.submit()
        var iterator = asked.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.0 == "Ops")
        #expect(first.1 == sheet.machineKey)
        // An engine whose Chiefs are this Mac's has no machine choice.
        let index = try #require(sheet.backend.itemArray.firstIndex { $0.representedObject as? String == "unii" })
        sheet.backend.selectItem(at: index)
        sheet.backend.sendAction(sheet.backend.action, to: sheet.backend.target)
        #expect(sheet.ownMachine.isHidden)
    }

    /// "Make it on this Mac" is the person's opt-in for a Claude Chief: off by default, so Create
    /// goes to `onCreate` (the cloud `chief.create`); ticked, Create goes to `onCreateOnThisMac`.
    /// An engine whose Chiefs are this Mac's already has no such choice.
    @MainActor @Test func theNewChiefSheetMakesAClaudeChiefOnThisMacOnlyWhenPicked() async throws {
        let sheet = HomeNewChiefSheet()
        _ = sheet.view
        #expect(sheet.thisMac.isHidden, "no host for this Mac: no box")
        let (asked, ask) = AsyncStream<(String, ChiefBackend, Bool)>.makeStream()
        sheet.onCreate = { name, backend in
            ask.yield((name, backend, false))
            return .offline
        }
        sheet.onCreateOnThisMac = { name, backend in
            ask.yield((name, backend, true))
            return .offline
        }
        #expect(sheet.chosenBackend == .claude)
        #expect(!sheet.thisMac.isHidden)
        #expect(sheet.thisMac.state == .off)
        sheet.name.stringValue = "Cloudy"
        sheet.submit()
        var iterator = asked.makeAsyncIterator()
        let plain = try #require(await iterator.next())
        #expect(plain.0 == "Cloudy" && plain.1 == .claude && !plain.2, "the default is the cloud create")

        let picked = HomeNewChiefSheet()
        _ = picked.view
        picked.onCreate = sheet.onCreate
        picked.onCreateOnThisMac = sheet.onCreateOnThisMac
        picked.name.stringValue = "Local"
        picked.thisMac.state = .on
        picked.submit()
        let local = try #require(await iterator.next())
        #expect(local.0 == "Local" && local.1 == .claude && local.2, "picked: made on this Mac")

        let index = try #require(picked.backend.itemArray.firstIndex { $0.representedObject as? String == "unii" })
        picked.backend.selectItem(at: index)
        _ = picked.backend.sendAction(picked.backend.action, to: picked.backend.target)
        #expect(picked.thisMac.isHidden, "UniiChat's Chiefs are this Mac's already")
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

    /// New Chief on the default engine (Claude) stays the signed-in account's cloud `chief.create`;
    /// this Mac's Chief owner is not asked.
    @MainActor @Test func aNewChiefOnTheDefaultEngineIsTheCloudChiefCreate() async throws {
        let calls = Calls()
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.home.localChiefCreator = { Self.localCreator(calls, chief: "agent_local01", conversation: "conv_local") }
        services.home.cloudChiefCreate = { name in
            await calls.sent("chief.create", ["display_name": .string(name)], "")
            return HomeChiefRecord(id: "agent_cloud01", name: name, isDefault: false, rev: 0, mainConversation: "conv_cloud", placed: true)
        }
        let outcome = await services.home.createChief(named: "Scout")
        #expect(outcome == .opened(ConversationID("conv_cloud")))
        #expect(await calls.sends.map(\.operation) == ["chief.create"])
        #expect(await calls.opens.isEmpty)
        #expect(services.home.pendingSelection == ConversationID("conv_cloud"))
        let action = await services.home.createChiefForAction(named: "Scout 2", backend: .claude)
        guard case .success(let record) = action else { Issue.record("\(action)"); return }
        #expect(record.id == "agent_cloud01")
        #expect(await calls.sends.map(\.operation) == ["chief.create", "chief.create"])
    }

    /// Picking "Make it on this Mac" makes a Claude Chief on this Mac's Chief owner
    /// (`chief.profile.create`, no harness for the default engine) and opens its DM; no cloud create.
    @MainActor @Test func aClaudeChiefPickedForThisMacIsMadeOnThisMacsChiefOwner() async throws {
        let calls = Calls()
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.home.localChiefCreator = { Self.localCreator(calls, chief: "agent_scout01", conversation: "conv_scout") }
        services.home.cloudChiefCreate = { _ in
            await calls.sent("chief.create", [:], "")
            throw CancellationError()
        }
        let outcome = await services.home.createChief(named: "Scout", backend: .claude, onThisMac: true)
        #expect(outcome == .opened(ConversationID("conv_scout")))
        let sent = try #require(await calls.sends.first)
        #expect(await calls.sends.count == 1)
        #expect(sent.operation == "chief.profile.create")
        #expect(sent.params == ["display_name": .string("Scout")])
        #expect(await calls.opens.count == 1)
        #expect(services.home.pendingSelection == ConversationID("conv_scout"))
    }

    @MainActor private static func localCreator(_ calls: Calls, chief: String, conversation: String) -> HomeLocalChiefCreator {
        HomeLocalChiefCreator(me: ConversationParticipant(id: "user_local", kind: .human, displayName: "Me"), send: { operation, params, key in
            await calls.sent(operation, params, key)
            return .object(["value": .object(["id": .string(chief), "display_name": params["display_name"] ?? .null])])
        }, open: { request in
            await calls.opened(request)
            return conversation
        })
    }

    /// Home's New Chief button (beside compose, which stays New Message) works as classic cmux's
    /// Chief list (ChiefConversationListView, #21063): one click makes another Chief at once, with
    /// no sheet to fill first, so the person can ask it something right away.
    @MainActor @Test(.timeLimit(.minutes(1))) func homesNewChiefButtonStartsANewChiefInOneClick() async throws {
        let calls = Calls()
        let (opened, open) = AsyncStream<Void>.makeStream()
        let services = AppServices(environment: AppEnvironment.current([:]))
        // The button makes a Chief where New Chief does by default: Claude's cloud `chief.create`.
        services.home.localChiefCreator = { Self.localCreator(calls, chief: "agent_local01", conversation: "conv_local") }
        services.home.cloudChiefCreate = { name in
            await calls.sent("chief.create", ["display_name": .string(name)], "")
            open.yield()
            return HomeChiefRecord(id: "agent_compose01", name: name, isDefault: false, rev: 0, mainConversation: "conv_compose", placed: true)
        }
        let page = TopHomePageView(services: services, windowKey: { "compose-new-chief" })
        #expect(page.list.newChief.accessibilityLabel() == HomeConversationStrings.chiefTitle)
        #expect(page.list.compose.accessibilityLabel() == HomeConversationStrings.newMessage)
        page.list.newChief.performClick(nil)
        var iterator = opened.makeAsyncIterator()
        _ = await iterator.next()
        let sent = try #require(await calls.sends.first)
        #expect(sent.operation == "chief.create")
        // No Chief is listed in this page yet, so the name is the Chief's own.
        #expect(sent.params == ["display_name": .string(HomeStrings.chiefName)])
        #expect(await calls.opens.isEmpty, "this Mac's Chief owner is not asked")
    }

    /// The button counts the names the list shows (records and renames being saved), not only the
    /// rows' conversation titles: a name only the list shows is not given to the new Chief.
    @MainActor @Test(.timeLimit(.minutes(1))) func theNewChiefButtonSkipsANameTheListShows() async throws {
        let calls = Calls()
        let (opened, open) = AsyncStream<Void>.makeStream()
        let services = AppServices(environment: AppEnvironment.current([:]))
        // The button makes a Chief where New Chief does by default: Claude's cloud `chief.create`.
        services.home.localChiefCreator = { Self.localCreator(calls, chief: "agent_local01", conversation: "conv_local") }
        services.home.cloudChiefCreate = { name in
            await calls.sent("chief.create", ["display_name": .string(name)], "")
            open.yield()
            return HomeChiefRecord(id: "agent_named02", name: name, isDefault: false, rev: 0, mainConversation: "conv_named02", placed: true)
        }
        // A Chief the list shows as "Chief" (a rename being saved) while no row is titled so.
        services.home.chiefRenames.rename(ConversationID("conv_renamed"), to: HomeStrings.chiefName, record: nil)
        #expect(services.home.chiefNames[ConversationID("conv_renamed")] == HomeStrings.chiefName)
        let page = TopHomePageView(services: services, windowKey: { "new-chief-shown-names" })
        page.list.newChief.performClick(nil)
        var iterator = opened.makeAsyncIterator()
        _ = await iterator.next()
        let sent = try #require(await calls.sends.first)
        #expect(sent.params == ["display_name": .string("\(HomeStrings.chiefName) 2")])
    }

    /// Each click's Chief gets the next free name ("Chief 2", "Chief 3"), never a second "Chief":
    /// identical rows could not be told apart, and `cmux chief` could not pick one of them by name.
    @Test func aNewChiefTakesTheNextFreeName() {
        let base = HomeStrings.chiefName
        #expect(HomeChiefName.next(taken: []) == base)
        #expect(HomeChiefName.next(taken: [base]) == "\(base) 2")
        #expect(HomeChiefName.next(taken: [base, "\(base) 2", "Scout"]) == "\(base) 3")
        #expect(HomeChiefName.next(taken: [base, "\(base) 3"]) == "\(base) 2")
    }

    /// A Chief with no message yet says what it is for, as classic cmux's list does ("Ask Chief
    /// anything"), so its name and that line sit beside its avatar as every other row's do.
    @Test func aChiefRowWithNoMessageYetSaysWhatItIsFor() {
        #expect(HomeSidebarItem.shownPreview("", isChief: true) == HomeConversationStrings.chiefEmptyPreview)
        #expect(HomeSidebarItem.shownPreview("Hi", isChief: true) == "Hi")
        #expect(HomeSidebarItem.shownPreview("", isChief: false).isEmpty)
        #expect(HomeConversationStrings.chiefEmptyPreview == "Ask Chief anything")
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
