@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import os
import Testing

/// Settings > Models (cmux-tui/docs/model-connections.md): the page's state composed from acpmux's
/// `_acpmux/connections`, each run's daemon call, a pasted API key reaching acpmux only as a Keychain
/// reference, a Claude setup token the same way, and Sign in with ChatGPT's wait loop from pending to done.
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
        /// `key.check`'s answer (nil: a daemon without the method, which answers `{}`).
        let keyCheck = OSAllocatedUnfairLock<String?>(initialState: nil)
        let beginURL = OSAllocatedUnfairLock(initialState: "https://auth.openai.com/oauth/authorize?client_id=app_EMoamEEZ73f0CkXaXp7hrann")
        let signedInPlan = OSAllocatedUnfairLock(initialState: false)
        /// `chatgpt.wait` fails: acpmux's error name, or "" for a daemon that does not answer.
        let waitFailure = OSAllocatedUnfairLock<String?>(initialState: nil)
        /// Whether acpmux has the one-click `claude_token.*` run; false answers method not found, as an older daemon.
        let claudeOneClick = OSAllocatedUnfairLock(initialState: false)
        let claudeURL = OSAllocatedUnfairLock<String?>(initialState: "https://claude.ai/oauth/authorize?abc123")
        /// `claude_token.wait` answers in order; the last repeats.
        let claudeWaits = OSAllocatedUnfairLock<[String]>(initialState: [])
    }

    struct NoAnswer: Error {}

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
    @MainActor final class Typed { var lines: [String] = [] }

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
           "plan":"plus","signed_in":true,"enabled":true,"default_for":["codex"],"serves_cloud":false},
          {"id":"claude-login","kind":"claude-login","provider":"anthropic","families":["claude"],"label":"Claude","email":"c@d.e",
           "plan":null,"signed_in":false,"enabled":false,"default_for":["claude"],"serves_cloud":false},
          {"id":"weird","kind":"not-a-kind","families":[]}\(chatgpt)
        ],"spread":\(spread),"order_explicit":false}
        """.utf8)
    }

    nonisolated static let claudeToken = Data("""
    {"connections":[{"id":"claude-token-1","kind":"claude-token","families":["claude"],"label":"Claude Code",
      "signed_in":true,"enabled":true,"default_for":["claude"],"serves_cloud":true}],"spread":true}
    """.utf8)

    private func make(daemon: Daemon, keys: Keys = Keys(), opened: Opened = Opened(), harnesses: SettingsHarnesses? = nil,
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
                case .claudeTokenAdd:
                    if daemon.refuseKeyAdd.withLock({ $0 }) { throw AcpmuxRPCError(code: -32602, name: "connections.bad_secret", message: "refused") }
                    return Self.claudeToken
                case .connectionsKeyCheck:
                    return Data((daemon.keyCheck.withLock { $0 } ?? "{}").utf8)
                case .connectionsKeyAdd:
                    if daemon.refuseKeyAdd.withLock({ $0 }) { throw AcpmuxRPCError(code: -32602, name: "connections.bad_secret", message: "refused") }
                    return Self.connections(plan: false)
                case .chatgptBegin:
                    return Data(#"{"attempt":"att-1","url":"\#(daemon.beginURL.withLock { $0 })"}"#.utf8)
                case .claudeTokenBegin, .claudeTokenWait, .claudeTokenCode, .claudeTokenCancel:
                    guard daemon.claudeOneClick.withLock({ $0 }) else { throw AcpmuxRPCError(code: -32601, name: nil, message: "method not found") }
                    if method == .claudeTokenBegin {
                        let url = daemon.claudeURL.withLock { $0 }.map { "\"\($0)\"" } ?? "null"
                        return Data(#"{"attempt":"ct-1","url":\#(url)}"#.utf8)
                    }
                    guard method == .claudeTokenWait else { return Data("{}".utf8) }
                    let status = daemon.claudeWaits.withLock { waits in waits.count > 1 ? waits.removeFirst() : waits.first ?? "pending" }
                    // A long poll holds a pending answer for a while (acpmux: up to 25 s).
                    if status == "pending" { try await Task.sleep(for: .milliseconds(200)) }
                    return Data(#"{"status":"\#(status)","connection":null,"error":\#(status == "failed" ? "\"claude_token.exited\"" : "null")}"#.utf8)
                case .chatgptWait:
                    if let failure = daemon.waitFailure.withLock({ $0 }) {
                        if failure.isEmpty { throw NoAnswer() }
                        throw AcpmuxRPCError(code: -32602, name: failure, message: "refused")
                    }
                    let status = daemon.waits.withLock { waits in waits.count > 1 ? waits.removeFirst() : waits.first ?? "pending" }
                    if status == "done" { daemon.signedInPlan.withLock { $0 = true } }
                    return Data(#"{"status":"\#(status)","connection":null,"error":\#(status == "failed" ? "\"no_plan_scope\"" : "null")}"#.utf8)
                default:
                    return Data("{}".utf8)
                }
            },
            keys: keys,
            openURL: { opened.urls.append($0) },
            harnesses: harnesses,
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
            "email": .null, "plan": "plus", "signedIn": true, "enabled": true, "defaultFor": ["codex"], "servesCloud": false,
        ])
        #expect(rows[1]["signedIn"] == .bool(false))
        #expect(rows[1]["serves_cloud"] == nil)
        // Revision 2: no team gateway on the page.
        #expect(state["organization"]?["gateway"] == nil)
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
        // An empty paste or an unknown provider never reaches the Keychain.
        await #expect(throws: PageError.self) {
            _ = try await models.run(["action": "addKey", "provider": "openai", "key": " \n\u{200B} "], context: click)
        }
        await #expect(throws: PageError.self) {
            _ = try await models.run(["action": "addKey", "provider": "acme", "key": "sk-0123456789"], context: click)
        }
        #expect(keys.stored.withLock { $0 }.count == 1)
    }

    @Test func aWrappedKeySavesAsOneWordAfterTheProvidersCheck() async throws {
        let daemon = Daemon()
        daemon.keyCheck.withLock { $0 = #"{"result":"ok","save":true,"message":null}"# }
        let keys = Keys()
        let models = make(daemon: daemon, keys: keys)
        _ = try await models.run(["action": "addKey", "provider": "openai",
                                  "key": "  sk-proj-0123\n4567 89ab\u{200B}cdef\r\n"], context: click)
        #expect(keys.stored.withLock { $0 } == ["keychain:cmux-model-key/openai-test": "sk-proj-0123456789abcdef"])
        let methods = daemon.calls.withLock { $0 }.map(\.method)
        let check = try #require(methods.firstIndex(of: "_acpmux/connections/key.check"))
        let add = try #require(methods.firstIndex(of: "_acpmux/connections/key.add"))
        #expect(check < add)
        #expect(daemon.calls.withLock { $0 }[check].params == ["provider": "openai", "secret": "keychain:cmux-model-key/openai-test"])
        #expect(keys.deleted.withLock { $0 }.isEmpty)
    }

    @Test func aKeyTheProviderRefusesIsTakenBackOutAndSaid() async throws {
        let daemon = Daemon()
        daemon.keyCheck.withLock { $0 = #"{"result":"bad_key","save":false,"message":"Key rejected by OpenAI"}"# }
        let keys = Keys()
        let models = make(daemon: daemon, keys: keys)
        let refusal = await #expect(throws: PageError.self) {
            _ = try await models.run(["action": "addKey", "provider": "openai", "key": "sk-proj-WRONG0123456789"], context: click)
        }
        #expect(refusal?.code == "cmux.models.key_rejected")
        #expect(refusal?.message == "Key rejected by OpenAI")
        #expect(keys.deleted.withLock { $0 } == ["keychain:cmux-model-key/openai-test"])
        #expect(!daemon.calls.withLock { $0 }.contains { $0.method == "_acpmux/connections/key.add" })
        // A provider that does not answer saves anyway.
        daemon.keyCheck.withLock { $0 = #"{"result":"unreachable","save":true,"message":null}"# }
        _ = try await models.run(["action": "addKey", "provider": "openai", "key": "sk-proj-AWAY0123456789"], context: click)
        #expect(daemon.calls.withLock { $0 }.contains { $0.method == "_acpmux/connections/key.add" })
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

    /// Leo, 2026-11-25: "what about other ones? chatgpt?": OpenAI's sign-in opens in cmux's own browser,
    /// as Claude's does, never the person's.
    @Test func chatGPTSignInOpensInCmuxsOwnBrowser() async throws {
        let daemon = Daemon()
        daemon.waits.withLock { $0 = ["done"] }
        let opened = Opened()
        let inApp = Opened()
        let harnesses = SettingsHarnesses(environment: { nil }, openTerminal: { _ in false },
                                          openSignInPage: { url, _ in inApp.urls.append(url); return {} })
        let models = make(daemon: daemon, opened: opened, harnesses: harnesses)
        _ = try await models.run(["action": "connectChatGPT"], context: click)
        #expect(inApp.urls.map(\.host) == ["auth.openai.com"])
        #expect(opened.urls.isEmpty)
        await models.chatgptTask?.value
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

    @Test func addClaudeTokenPassesOnlyTheKeychainReference() async throws {
        let daemon = Daemon()
        let keys = Keys()
        let models = make(daemon: daemon, keys: keys)
        let token = "sk-ant-oat01-THE-RAW-TOKEN-0123456789"
        _ = try await models.run(["action": "addClaudeToken", "token": .string(token + "\n"), "label": "Max"], context: click)
        #expect(keys.stored.withLock { $0 } == ["keychain:cmux-model-key/claude-token-test": token])
        let add = try #require(daemon.calls.withLock { $0 }.first { $0.method == "_acpmux/connections/claude_token.add" })
        #expect(add.params == ["secret": "keychain:cmux-model-key/claude-token-test", "label": "Max"])
        #expect(!daemon.calls.withLock { $0 }.contains { $0.params.values.contains { $0.contains("THE-RAW-TOKEN") } })
        #expect(!models.state.compactText.contains("THE-RAW-TOKEN"))
        // acpmux's answer shows at once: a claude-token connection of Anthropic that serves Cloud.
        let row = try #require(models.state["personal"]?["connections"]?.arrayValue?.first)
        #expect(row["kind"] == "claude-token")
        #expect(row["provider"] == "anthropic")
        #expect(row["servesCloud"] == .bool(true))
    }

    @Test func aClaudeTokenNeedsItsShape() async throws {
        let daemon = Daemon()
        let keys = Keys()
        let models = make(daemon: daemon, keys: keys)
        for token in ["sk-ant-api03-not-a-setup-token", "sk-ant-oat01-", "sk-ant-oatxx-abc", "sk-ant-oat01-a│b", "sk-ant-oat01-a\"", "  \n ", ""] {
            await #expect(throws: PageError.self) {
                _ = try await models.run(["action": "addClaudeToken", "token": .string(token)], context: click)
            }
        }
        #expect(keys.stored.withLock { $0 }.isEmpty)
        #expect(daemon.calls.withLock { $0 }.isEmpty)
        // A refused add takes the Keychain item back out.
        daemon.refuseKeyAdd.withLock { $0 = true }
        await #expect(throws: PageError.self) {
            _ = try await models.run(["action": "addClaudeToken", "token": "sk-ant-oat01-abc"], context: click)
        }
        #expect(keys.deleted.withLock { $0 } == ["keychain:cmux-model-key/claude-token-test"])
    }

    @Test func aWrappedOrPaddedClaudeTokenIsSavedWithoutItsWhitespace() async throws {
        // Leo, 2026-11-25: "your terminal sometimes gets cut off with spaces and the text entry doesnt
        // strip spaces". A token wrapped across lines, padded with spaces or a zero-width space is the
        // one token the terminal printed.
        let token = "sk-ant-oat01-ABCdef_0123-456789xyz"
        let pasted = "  sk-ant-oat01-ABCdef_0123\n   -456789\u{200B}xyz \r\n\t"
        #expect(SettingsModels.withoutWhitespace(pasted) == token)
        #expect(SettingsModels.isClaudeToken(SettingsModels.withoutWhitespace(pasted)))
        let daemon = Daemon()
        let keys = Keys()
        let models = make(daemon: daemon, keys: keys)
        _ = await models.loadedState()
        _ = try await models.run(["action": "addClaudeToken", "token": .string(pasted)], context: click)
        #expect(keys.stored.withLock { $0 } == ["keychain:cmux-model-key/claude-token-test": token])
    }

    @Test func claudeSetupTokenOnAnOlderDaemonOpensATerminalTabRunningIt() async throws {
        let daemon = Daemon()
        let typed = Typed()
        let harnesses = SettingsHarnesses(environment: { nil }, openTerminal: { line in typed.lines.append(line); return true })
        let models = make(daemon: daemon, harnesses: harnesses)
        _ = try await models.run(["action": "claudeSetupToken"], context: click)
        #expect(typed.lines == ["claude setup-token"])
        // Only from the person's own gesture.
        let script = PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: false, gestureEvent: nil)
        await #expect(throws: PageError.self) { _ = try await models.run(["action": "claudeSetupToken"], context: script) }
        #expect(typed.lines.count == 1)
    }

    /// Leo, 2026-11-25: "surely we can minimize the cruft all around here" (no copy and paste at all):
    /// one click runs `claude setup-token` inside acpmux, opens Claude's page and waits for the connection.
    @Test func claudeConnectsInOneClickWithNoTerminalAndNoPaste() async throws {
        let daemon = Daemon()
        daemon.claudeOneClick.withLock { $0 = true }
        daemon.claudeWaits.withLock { $0 = ["pending", "done"] }
        let opened = Opened()
        let typed = Typed()
        let harnesses = SettingsHarnesses(environment: { nil }, openTerminal: { line in typed.lines.append(line); return true })
        let models = make(daemon: daemon, opened: opened, harnesses: harnesses)
        _ = await models.loadedState()
        let answer = try await models.run(["action": "connectClaudeToken", "label": "Claude"], context: click)
        #expect(answer == ["attempt": "ct-1"])
        #expect(opened.urls.map(\.host) == ["claude.ai"])
        #expect(models.state["claudeToken"] == ["attempt": "ct-1", "phase": "signing_in", "error": .null, "saved": false])
        await models.claudeTokenTask?.value
        #expect(models.state["claudeToken"] == ["attempt": .null, "phase": .null, "error": .null, "saved": true])
        let calls = daemon.calls.withLock { $0 }
        #expect(calls.first { $0.method == "_acpmux/connections/claude_token.begin" }?.params == ["label": "Claude"])
        #expect(calls.filter { $0.method == "_acpmux/connections/claude_token.wait" }.count == 2)
        #expect(typed.lines.isEmpty)
        // The Cloud card's Set up Claude (`claudeSetupToken`) takes the same one click on this daemon.
        daemon.claudeWaits.withLock { $0 = ["done"] }
        _ = try await models.run(["action": "claudeSetupToken"], context: click)
        await models.claudeTokenTask?.value
        #expect(typed.lines.isEmpty)
    }

    @Test func claudeOneClickShowsItsFailureAndCancels() async throws {
        let daemon = Daemon()
        daemon.claudeOneClick.withLock { $0 = true }
        daemon.claudeWaits.withLock { $0 = ["failed"] }
        let models = make(daemon: daemon)
        _ = try await models.run(["action": "connectClaudeToken"], context: click)
        await models.claudeTokenTask?.value
        #expect(models.state["claudeToken"] == ["attempt": .null, "phase": .null, "error": "claude_token.exited", "saved": false])
        daemon.claudeWaits.withLock { $0 = ["pending"] }
        _ = try await models.run(["action": "connectClaudeToken"], context: click)
        _ = try await models.run(["action": "claudeTokenCode", "code": " abc\n def "], context: click)
        #expect(daemon.calls.withLock { $0 }.contains(Call(method: "_acpmux/connections/claude_token.code", params: ["attempt": "ct-1", "code": "abcdef"])))
        _ = try await models.run(["action": "cancelClaudeToken"], context: click)
        #expect(daemon.calls.withLock { $0 }.contains(Call(method: "_acpmux/connections/claude_token.cancel", params: ["attempt": "ct-1"])))
        #expect(models.state["claudeToken"]?["attempt"] == .null)
        #expect(models.state["claudeToken"]?["saved"] == false)
    }

    /// A run that printed its token with no link first (`url: null`) opens nothing and is saved, not `bad_reply`.
    @Test func aClaudeRunWithNoLinkOpensNothingAndSaves() async throws {
        let daemon = Daemon()
        daemon.claudeOneClick.withLock { $0 = true }
        daemon.claudeURL.withLock { $0 = nil }
        daemon.claudeWaits.withLock { $0 = ["done"] }
        let opened = Opened()
        let models = make(daemon: daemon, opened: opened)
        let answer = try await models.run(["action": "connectClaudeToken"], context: click)
        #expect(answer == ["attempt": "ct-1"])
        #expect(opened.urls.isEmpty)
        await models.claudeTokenTask?.value
        #expect(models.state["claudeToken"] == ["attempt": .null, "phase": .null, "error": .null, "saved": true])
    }

    @Test func onlyClaudesSignInPageIsOpened() async throws {
        let daemon = Daemon()
        daemon.claudeOneClick.withLock { $0 = true }
        daemon.claudeURL.withLock { $0 = "https://claude.ai.evil.example/oauth" }
        let opened = Opened()
        let models = make(daemon: daemon, opened: opened)
        await #expect(throws: PageError.self) { _ = try await models.run(["action": "connectClaudeToken"], context: click) }
        #expect(opened.urls.isEmpty)
        #expect(daemon.calls.withLock { $0 }.last?.method == "_acpmux/connections/claude_token.cancel")
        let script = PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: false, gestureEvent: nil)
        await #expect(throws: PageError.self) { _ = try await models.run(["action": "connectClaudeToken"], context: script) }
    }

    @Test func orgKeyNeedsAnExplicitKeyOrNull() async throws {
        let models = make(daemon: Daemon())
        await #expect(throws: PageError.self) { _ = try await models.run(["action": "orgKey", "agent": "claude"], context: click) }
    }

    @Test func chatGPTWaitRefusedEndsTheAttemptWithItsCode() async throws {
        let daemon = Daemon()
        daemon.waitFailure.withLock { $0 = "chatgpt.unknown_attempt" }
        let models = make(daemon: daemon)
        _ = try await models.run(["action": "connectChatGPT"], context: click)
        await models.chatgptTask?.value
        // acpmux's own refusal ends it at once, with its code, and the attempt is cancelled.
        let methods = daemon.calls.withLock { $0 }.map(\.method)
        #expect(methods.filter { $0 == "_acpmux/connections/chatgpt.wait" }.count == 1)
        #expect(daemon.calls.withLock { $0 }.last == Call(method: "_acpmux/connections/chatgpt.cancel", params: ["attempt": "att-1"]))
        #expect(models.state["chatgpt"] == ["attempt": .null, "error": "chatgpt.unknown_attempt"])
    }

    @Test func chatGPTWaitWithNoAnswerCancelsAfterItsFailures() async throws {
        let daemon = Daemon()
        daemon.waitFailure.withLock { $0 = "" }
        let models = make(daemon: daemon)
        _ = try await models.run(["action": "connectChatGPT"], context: click)
        await models.chatgptTask?.value
        let methods = daemon.calls.withLock { $0 }.map(\.method)
        #expect(methods.filter { $0 == "_acpmux/connections/chatgpt.wait" }.count == SettingsModels.chatgptFailures)
        #expect(methods.last == "_acpmux/connections/chatgpt.cancel")
        #expect(models.state["chatgpt"] == ["attempt": .null, "error": "unreachable"])
    }

    @Test func aConnectionsChangedNoteShowsItsStateWithoutARead() async throws {
        let daemon = Daemon()
        let models = make(daemon: daemon)
        _ = await models.loadedState()
        let reads = daemon.calls.withLock { $0 }.count
        let note = #"{"jsonrpc":"2.0","method":"_acpmux/connections.changed","params":"#
            + String(decoding: Self.claudeToken, as: UTF8.self) + "}"
        await models.changed(Data(note.utf8))
        #expect(daemon.calls.withLock { $0 }.count == reads)
        #expect(models.state["personal"]?["connections"]?.arrayValue?.map { $0["id"]?.stringValue } == ["claude-token-1"])
        // A note without a state reads it again.
        await models.changed(Data(#"{"jsonrpc":"2.0","method":"_acpmux/connections.changed"}"#.utf8))
        #expect(daemon.calls.withLock { $0 }.last?.method == "_acpmux/connections")
    }
}
