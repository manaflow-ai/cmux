@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import os
import Testing

/// Settings > Models (cmux-tui/docs/model-connections.md): the page's state composed from acpmux's
/// `_acpmux/connections`, each run's daemon call, a pasted API key reaching acpmux only as a Keychain
/// reference, and Sign in with ChatGPT's wait loop from pending to done.
@MainActor struct SettingsModelsTests {
    struct Call: Sendable, Equatable {
        let method: String
        let params: [String: String]
    }

    /// The daemon's scripted answers and every call it got.
    final class Daemon: Sendable {
        let calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
        /// `chatgpt.wait` answers in order; the last repeats.
        let waits = OSAllocatedUnfairLock<[String]>(initialState: [])
        let refuseKeyAdd = OSAllocatedUnfairLock(initialState: false)
        let beginURL = OSAllocatedUnfairLock(initialState: "https://auth.openai.com/api/accounts/authorize?client_id=dynamic_agent_client")
        let signedInPlan = OSAllocatedUnfairLock(initialState: false)
    }

    /// The Keychain stand-in: what was stored and removed, by reference.
    final class Keys: ModelKeyStoring {
        let stored = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        let deleted = OSAllocatedUnfairLock<[String]>(initialState: [])
        func store(_ key: String, provider: String) async throws -> String {
            let reference = "keychain:cmux-model-key/\(provider)-test"
            stored.withLock { $0[reference] = key }
            return reference
        }
        func delete(_ reference: String) async { deleted.withLock { $0.append(reference) } }
    }

    @MainActor final class Opened { var urls: [URL] = [] }

    /// `models.spreadUsage` as the settings writer holds it.
    @MainActor final class Setting {
        var on = false
        var written: [Bool] = []
    }

    nonisolated static func connections(plan: Bool, spread: Bool = true) -> Data {
        let chatgpt = plan ? """
          ,{"id":"chatgpt-1","kind":"chatgpt-plan","provider":"openai","families":["codex"],"label":"ChatGPT","email":"a@b.c",
            "plan":"pro","signed_in":true,"enabled":true,"default_for":[],"serves_cloud":true}
        """ : ""
        return Data("""
        {"connections":[
          {"id":"codex-login","kind":"codex-login","provider":"openai","families":["codex"],"label":"ChatGPT","email":null,
           "plan":"plus","signed_in":true,"enabled":true,"default_for":["codex"],"serves_cloud":true},
          {"id":"claude-login","kind":"claude-login","provider":"anthropic","families":["claude"],"label":"Claude","email":"c@d.e",
           "plan":null,"signed_in":false,"enabled":false,"default_for":["claude"],"serves_cloud":true},
          {"id":"weird","kind":"not-a-kind","families":[]}\(chatgpt)
        ],"spread":\(spread),"order_explicit":false}
        """.utf8)
    }

    private func make(daemon: Daemon, keys: Keys = Keys(), opened: Opened = Opened(),
                      spread: (read: @MainActor () -> Bool, write: @MainActor (Bool) async throws -> Void)? = nil) -> SettingsModels {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-models-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
                                            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        return SettingsModels(
            environment: { environment },
            call: { _, method, params in
                let flat = params.compactMapValues { value -> String? in
                    if let text = value as? String { return text }
                    if let flag = value as? Bool { return flag ? "true" : "false" }
                    if let list = value as? [String] { return list.joined(separator: ",") }
                    return nil
                }
                daemon.calls.withLock { $0.append(Call(method: method.rawValue, params: flat)) }
                switch method {
                case .connections, .connectionsSpreadSet, .connectionsOrderSet:
                    return Self.connections(plan: daemon.signedInPlan.withLock { $0 }, spread: flat["on"].map { $0 == "true" } ?? true)
                case .connectionsKeyAdd:
                    if daemon.refuseKeyAdd.withLock({ $0 }) { throw AcpmuxRPCError(code: -32602, name: "connections.bad_secret", message: "refused") }
                    return Self.connections(plan: false)
                case .chatgptBegin:
                    return Data(#"{"attempt":"att-1","url":"\#(daemon.beginURL.withLock { $0 })"}"#.utf8)
                case .chatgptWait:
                    let status = daemon.waits.withLock { waits in waits.count > 1 ? waits.removeFirst() : waits.first ?? "pending" }
                    if status == "done" { daemon.signedInPlan.withLock { $0 = true } }
                    return Data(#"{"status":"\#(status)","connection":null,"error":\#(status == "failed" ? "\"no_plan_scope\"" : "null")}"#.utf8)
                default:
                    return Data("{}".utf8)
                }
            },
            keys: keys,
            openURL: { opened.urls.append($0) },
            spreadSetting: spread?.read,
            writeSpreadSetting: spread?.write)
    }

    private var click: PageCallContext {
        PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: true, gestureEvent: 1)
    }

    @Test func stateComposesAcpmuxConnectionsAsThePageDrawsThem() async throws {
        let daemon = Daemon()
        let models = make(daemon: daemon)
        let state = await models.loadedState()
        let personal = try #require(state["personal"])
        #expect(personal["available"] == .bool(true))
        #expect(personal["spread"] == .bool(true))
        let rows = try #require(personal["connections"]?.arrayValue)
        // An unknown kind is not drawn; the rest keep acpmux's order, in the page's camelCase.
        #expect(rows.map { $0["id"]?.stringValue } == ["codex-login", "claude-login"])
        #expect(rows[0] == [
            "id": "codex-login", "kind": "codex-login", "provider": "openai", "families": ["codex"], "label": "ChatGPT",
            "email": .null, "plan": "plus", "signedIn": true, "enabled": true, "defaultFor": ["codex"],
        ])
        #expect(rows[1]["signedIn"] == .bool(false))
        #expect(rows[1]["serves_cloud"] == nil)
        // No team: no organization connections and no members policy.
        #expect(state["organization"]?["team"] == .null)
        #expect(state["organization"]?["keys"] == .array([]))
        #expect(state["members"] == .null)
        #expect(state["chatgpt"] == ["attempt": .null, "error": .null])
    }

    @Test func theSettingIsTheSpreadWriterAndAcpmuxFollowsIt() async throws {
        let daemon = Daemon()
        let setting = Setting()
        let models = make(daemon: daemon, spread: (read: { setting.on }, write: { on in setting.written.append(on); setting.on = on }))
        // acpmux answers spread on; the setting says off: the read pushes the setting's value.
        let state = await models.loadedState()
        #expect(state["personal"]?["spread"] == .bool(false))
        #expect(daemon.calls.withLock { $0 }.contains(Call(method: "_acpmux/connections/spread.set", params: ["on": "false"])))
        _ = try await models.run(["action": "spread", "on": true], context: click)
        #expect(setting.written == [true])
        #expect(daemon.calls.withLock { $0 }.last == Call(method: "_acpmux/connections/spread.set", params: ["on": "true"]))
        #expect(models.state["personal"]?["spread"] == .bool(true))
    }

    @Test func addKeyPassesOnlyTheKeychainReference() async throws {
        let daemon = Daemon()
        let keys = Keys()
        let models = make(daemon: daemon, keys: keys)
        _ = await models.loadedState()
        let key = "sk-ant-api03-THE-RAW-KEY-0123456789"
        _ = try await models.run(["action": "addKey", "provider": "anthropic", "key": .string(key + "\n"), "label": "Work"], context: click)
        #expect(keys.stored.withLock { $0 } == ["keychain:cmux-model-key/anthropic-test": key])
        let add = try #require(daemon.calls.withLock { $0 }.first { $0.method == "_acpmux/connections/key.add" })
        #expect(add.params == ["provider": "anthropic", "secret": "keychain:cmux-model-key/anthropic-test", "label": "Work"])
        // The key reaches no daemon call and no page state.
        #expect(!daemon.calls.withLock { $0 }.contains { $0.params.values.contains { $0.contains("THE-RAW-KEY") } })
        #expect(!models.state.compactText.contains("THE-RAW-KEY"))
        #expect(keys.deleted.withLock { $0 }.isEmpty)
    }

    @Test func aRefusedKeyAddTakesTheKeychainItemBackOut() async throws {
        let daemon = Daemon()
        daemon.refuseKeyAdd.withLock { $0 = true }
        let keys = Keys()
        let models = make(daemon: daemon, keys: keys)
        await #expect(throws: PageError.self) {
            _ = try await models.run(["action": "addKey", "provider": "openai", "key": "sk-proj-0123456789abcdef"], context: click)
        }
        #expect(keys.deleted.withLock { $0 } == ["keychain:cmux-model-key/openai-test"])
        // A key with a space or an unknown provider never reaches the Keychain.
        await #expect(throws: PageError.self) {
            _ = try await models.run(["action": "addKey", "provider": "openai", "key": "two words"], context: click)
        }
        await #expect(throws: PageError.self) {
            _ = try await models.run(["action": "addKey", "provider": "acme", "key": "sk-0123456789"], context: click)
        }
        #expect(keys.stored.withLock { $0 }.count == 1)
    }

    @Test func changesNeedThePersonsGesture() async throws {
        let daemon = Daemon()
        let keys = Keys()
        let models = make(daemon: daemon, keys: keys)
        let script = PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: false, gestureEvent: nil)
        for action: JSONValue in [["action": "addKey", "provider": "openai", "key": "sk-0123456789"], ["action": "spread", "on": false],
                                  ["action": "connectChatGPT"], ["action": "order", "ids": ["codex-login"]]] {
            await #expect(throws: PageError.self) { _ = try await models.run(action, context: script) }
        }
        #expect(keys.stored.withLock { $0 }.isEmpty)
        #expect(daemon.calls.withLock { $0 }.isEmpty)
    }

    @Test func chatGPTSignInGoesFromPendingToDone() async throws {
        let daemon = Daemon()
        daemon.waits.withLock { $0 = ["pending", "pending", "done"] }
        let opened = Opened()
        let models = make(daemon: daemon, opened: opened)
        _ = await models.loadedState()
        let answer = try await models.run(["action": "connectChatGPT"], context: click)
        #expect(answer == ["attempt": "att-1"])
        #expect(opened.urls.map(\.host) == ["auth.openai.com"])
        #expect(models.state["chatgpt"] == ["attempt": "att-1", "error": .null])
        await models.chatgptTask?.value
        #expect(daemon.calls.withLock { $0 }.filter { $0.method == "_acpmux/connections/chatgpt.wait" }.count == 3)
        #expect(models.state["chatgpt"] == ["attempt": .null, "error": .null])
        // Done reads the connections again: the new plan shows.
        #expect(models.state["personal"]?["connections"]?.arrayValue?.contains { $0["kind"] == "chatgpt-plan" } == true)
    }

    @Test func chatGPTSignInShowsItsFailure() async throws {
        let daemon = Daemon()
        daemon.waits.withLock { $0 = ["pending", "failed"] }
        let models = make(daemon: daemon)
        _ = try await models.run(["action": "connectChatGPT"], context: click)
        await models.chatgptTask?.value
        #expect(models.state["chatgpt"] == ["attempt": .null, "error": "no_plan_scope"])
    }

    @Test func onlyOpenAIsSignInPageIsOpened() async throws {
        let daemon = Daemon()
        daemon.beginURL.withLock { $0 = "https://evil.example/authorize" }
        let opened = Opened()
        let models = make(daemon: daemon, opened: opened)
        await #expect(throws: PageError.self) { _ = try await models.run(["action": "connectChatGPT"], context: click) }
        #expect(opened.urls.isEmpty)
        #expect(models.state["chatgpt"]?["attempt"] == .null)
    }

    @Test func aTeamKeyKindFollowsItsShape() {
        #expect(SettingsModels.kind(of: "sk-ant-oat01-abc") == "oauth")
        #expect(SettingsModels.kind(of: #"{"tokens":{}}"#) == "oauth")
        #expect(SettingsModels.kind(of: "sk-proj-abc") == "api_key")
    }

    @Test func theKeychainLineQuotesItsWords() {
        #expect(KeychainModelKeyStore.quoted(#"a"b\c"#) == #""a\"b\\c""#)
    }

    @Test func theGatewayAnswerMapsToTheCardsShape() {
        #expect(SettingsModels.gateway(["ok": true, "gateway": ["mode": "gateway", "machine": "vm_1", "online": true, "kind": "x"]])
            == ["mode": "gateway", "machine": "vm_1", "online": true])
        #expect(SettingsModels.gateway(["ok": true, "gateway": ["mode": "personal"]]) == ["mode": "off", "machine": .null, "online": false])
        #expect(SettingsModels.gateway(["ok": false, "error": ["code": "auth.forbidden"]]) == nil)
    }
}
