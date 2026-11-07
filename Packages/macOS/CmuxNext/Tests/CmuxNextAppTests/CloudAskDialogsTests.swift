@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// An agent's Cloud start ask as a dialog of `cmux agents dialog list|answer` (``CloudAskDialogs``):
/// listed with its choices and answer commands; Start taken only from the person or a delegated
/// agent (cmux-cloud-start-core `ask`), Not now from anyone; and the agent's run answering
/// pending as soon as its card asks instead of waiting in silence.
@MainActor @Suite(.serialized)
struct CloudAskDialogsTests {
    typealias Asks = CloudStartSessionAsksTests

    static let person: [String: JSONValue] = ["origin": "cli"]
    static let agent: [String: JSONValue] = ["origin": "cli", "caller": ["agent_session": "sess-1"]]
    static let mcp: [String: JSONValue] = ["origin": "mcp"]

    /// An ask open in chat `tab`, its card shown.
    static func open(_ asks: CloudStartSessionAsks, _ cards: Asks.Cards, _ tab: String) async -> Task<UUID, any Error> {
        let task = Task { try await asks.ask(tab: tab, text: "The agent asks to start a claude session on Cloud machine dev.", asked: Asks.asked,
                                             account: Asks.account, now: { Asks.account }, caller: "sess-1") }
        await cards.shownIn(tab)
        return task
    }

    static func refusal(_ body: () throws -> JSONValue) -> ControlError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? ControlError
        }
    }

    @Test func aWaitingAskIsListedWithItsChoicesAndCommands() async throws {
        let asks = CloudStartSessionAsks(), cards = Asks.Cards()
        cards.install(asks)
        let task = await Self.open(asks, cards, "chat-1")
        let dialogs = CloudAskDialogs(asks: { asks }, delegated: { false })
        let items = dialogs.items()
        #expect(items.count == 1)
        let item = try #require(items.first?.objectValue)
        let id = try #require(item["id"]?.stringValue)
        #expect(id.hasPrefix("cloud-start-") && dialogs.owns(id))
        #expect(item["kind"] == "question")
        #expect(item["tab_id"] == "chat-1")
        #expect(item["agent_session"] == "sess-1")
        #expect(item["start_by"] == "person")
        #expect(item["answer_commands"]?.objectValue?["start"] == .string("cmux agents dialog answer \(id) --selection start"))
        let options = item["questions"]?.arrayValue?.first?.objectValue?["options"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue }
        #expect(options == ["start", "notNow"])
        _ = try dialogs.reply(id, selection: "notNow", params: Self.person)
        _ = try? await task.value
        #expect(dialogs.items().isEmpty)
    }

    @Test func anAgentIsRefusedStartWithoutTheDelegationAndThePersonMayStart() async throws {
        let asks = CloudStartSessionAsks(), cards = Asks.Cards()
        cards.install(asks)
        let task = await Self.open(asks, cards, "chat-2")
        let dialogs = CloudAskDialogs(asks: { asks }, delegated: { false })
        let id = try #require(asks.waiting.first?.dialog)
        for params in [Self.agent, Self.mcp, [:], ["origin": "cli", "caller": ["home_chat": true]]] {
            #expect(Self.refusal { try dialogs.reply(id, selection: "start", params: params) }?.code == "person_required")
        }
        #expect(asks.waiting.count == 1, "a refused Start leaves the card asking")
        let reply = try dialogs.reply(id, selection: "Start", params: Self.person)
        #expect(reply.objectValue?["status"] == "answered")
        _ = try await task.value
        #expect(asks.waiting.isEmpty)
    }

    /// Only the first answer is taken: a Start after Not now (or a click after a CLI answer) says
    /// the ask is gone instead of reporting a start that never happens.
    @Test func onlyTheFirstAnswerIsTaken() async throws {
        let asks = CloudStartSessionAsks(), cards = Asks.Cards()
        cards.install(asks)
        let task = await Self.open(asks, cards, "chat-5")
        let dialogs = CloudAskDialogs(asks: { asks }, delegated: { false })
        let id = try #require(asks.waiting.first?.dialog)
        // Both in one main-actor turn, before the ask resumes.
        _ = try dialogs.reply(id, selection: "notNow", params: Self.person)
        #expect(Self.refusal { try dialogs.reply(id, selection: "start", params: Self.person) }?.code == "not_found")
        cards.click("chat-5", "start")
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.declined(Asks.asked))) { _ = try await task.value }
    }

    /// A listed label in any language is its option; the rules read only the ids.
    @Test func aShownLabelIsItsOption() {
        let dialog = CloudAskDialog(id: "cloud-start-x")
        #expect(dialog.selection(" Démarrer ", start: "Démarrer", notNow: "Pas maintenant") == "start")
        #expect(dialog.selection("開始しない", start: "開始", notNow: "開始しない") == "notNow")
        #expect(dialog.selection("start", start: "Démarrer", notNow: "Pas maintenant") == "start")
        #expect(CloudAskDialog.owns("cloud-start-x") && !CloudAskDialog.owns("perm-1"))
    }

    @Test func aDelegatedAgentMayStart() async throws {
        let asks = CloudStartSessionAsks(), cards = Asks.Cards()
        cards.install(asks)
        let task = await Self.open(asks, cards, "chat-3")
        let dialogs = CloudAskDialogs(asks: { asks }, delegated: { true })
        #expect(dialogs.items().first?.objectValue?["start_by"] == "person_or_agent")
        let id = try #require(asks.waiting.first?.dialog)
        _ = try dialogs.reply(id, selection: "start", params: Self.agent)
        _ = try await task.value
    }

    @Test func anyoneMayDeclineAndAnEndedAskIsGone() async throws {
        let asks = CloudStartSessionAsks(), cards = Asks.Cards()
        cards.install(asks)
        let task = await Self.open(asks, cards, "chat-4")
        let dialogs = CloudAskDialogs(asks: { asks }, delegated: { false })
        let id = try #require(asks.waiting.first?.dialog)
        #expect(Self.refusal { try dialogs.reply(id, selection: "always", params: Self.person) }?.code == "invalid_params")
        let reply = try dialogs.reply(id, selection: "Not now", params: Self.mcp)
        #expect(reply.objectValue?["status"] == "denied")
        await #expect(throws: ActionFailure(message: CloudStartSessionStrings.declined(Asks.asked))) { _ = try await task.value }
        #expect(Self.refusal { try dialogs.reply(id, selection: "start", params: Self.person) }?.code == "not_found")
        #expect(!asks.answer(dialog: id, start: true))
    }

    /// The agent's run answers pending with the dialog as soon as its card asks; the same ask
    /// again waits for the person's answer and gets the run's end.
    @Test func anAgentsRunAnswersPendingAsSoonAsItsCardAsks() async throws {
        let runs = CloudStartSessionRuns()
        runs.sleep = Asks.waits
        let (gate, open) = AsyncStream<Void>.makeStream()
        defer { open.finish() }
        let asking: CloudStartSessionRuns.Fields = ["pending": .bool(true), "dialog_id": .string("cloud-start-x")]
        let work: @MainActor () async throws -> CloudStartSessionRuns.Fields = {
            runs.asking(Asks.key, asking)
            for await _ in gate { break }
            return ["session_id": .string("s-1")]
        }
        let first = try await runs.answer(Asks.key, within: .seconds(190), pending: Asks.pending, forgotten: Asks.forgotten, early: true, work)
        #expect(first == asking)
        #expect(runs.waitingCount == 0, "the early caller holds nothing on the run")
        runs.sleep = { _ in
            open.yield(())
            try? await Task.sleep(for: .seconds(3600))
        }
        let again = try await runs.answer(Asks.key, within: .seconds(190), pending: Asks.pending, forgotten: Asks.forgotten, early: true, work)
        #expect(again["session_id"] == .string("s-1"), "the same ask again waits for the answer")
    }

    /// Only the person changes the delegation (an agent's settings write of the key is refused), and
    /// it is on by default: an agent's start in a chat asks nobody unless the person turned it off
    /// (Leo, 2026-11-03, on the Start card: "shouldn't have needed to ask me").
    @Test func theDelegationIsThePersonsAndOnByDefault() {
        #expect(SettingsSchema.agentRefusedKeys[CloudAgentStartSetting.key] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains(CloudAgentStartSetting.key))
        #expect(CloudAgentStartSetting().delegated(in: .object([:])))
        #expect(CloudAgentStartSetting().delegated(in: ["cloud": ["agentsStartWithoutAsking": true]]))
        #expect(!CloudAgentStartSetting().delegated(in: ["cloud": ["agentsStartWithoutAsking": false]]))
        #expect(CloudAgentStartSetting().delegated(in: ["cloud": ["agentsStartWithoutAsking": "yes"]]))
        #expect(SettingsSchema.all.first { $0.path == CloudAgentStartSetting.path }?.defaultValue == .bool(true))
    }
}
