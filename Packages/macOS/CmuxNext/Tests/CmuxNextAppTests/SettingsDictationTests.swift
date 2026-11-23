@testable import CmuxNextAccounts
@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import os
import Testing

/// Settings > Agent Chat's dictation engine (`cmux.settings.dictation.run`): the state is acpmux's
/// `_acpmux/voice/state`, a pasted key goes into the Keychain at the account that state names (never to
/// acpmux, the page or a log), and the check is acpmux's. Leo, 2026-11-22: "people should be able to add
/// their own api keys/whatever and toggle that voice mode and whatever to link up to their provider of
/// choice".
@MainActor struct SettingsDictationTests {
    /// The daemon's scripted state and every method it was asked.
    final class Daemon: Sendable {
        let methods = OSAllocatedUnfairLock<[String]>(initialState: [])
        let account = OSAllocatedUnfairLock<String?>(initialState: "openai@https://api.openai.com")
        let hasKey = OSAllocatedUnfairLock(initialState: false)
        let service = OSAllocatedUnfairLock(initialState: "cmux-voice-key")
    }

    /// The Keychain stand-in, by service and account.
    actor Keys: VoiceKeyStoring {
        private(set) var items: [String: String] = [:]
        private(set) var deleted: [String] = []

        func store(_ key: String, service: String, account: String) async throws {
            items["\(service)/\(account)"] = key
        }

        func delete(service: String, account: String) async {
            items["\(service)/\(account)"] = nil
            deleted.append("\(service)/\(account)")
        }
    }

    private func make(_ daemon: Daemon, _ keys: Keys) -> SettingsDictation {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-dictation-\(UUID().uuidString)")
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
                                            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        return SettingsDictation(environment: { environment }, call: { _, method, _ in
            daemon.methods.withLock { $0.append(method.rawValue) }
            switch method {
            case .voiceState:
                let account = daemon.account.withLock { $0 }.map { "\"\($0)\"" } ?? "null"
                let hasKey = daemon.hasKey.withLock { $0 }
                let service = daemon.service.withLock { $0 }
                return Data("""
                {"engine":"openai","label":"OpenAI","kind":"cloud","wire":"openaiTranscriptions","key":"required",
                 "url":"https://api.openai.com/v1","model":"gpt-4o-mini-transcribe","keyAccount":\(account),
                 "keyService":"\(service)","hasKey":\(hasKey),"providers":[]}
                """.utf8)
            case .voiceCheck:
                return Data(#"{"ok":false,"error":{"code":"key_missing","detail":""}}"#.utf8)
            default:
                return Data("{}".utf8)
            }
        }, keys: keys)
    }

    private var click: PageCallContext {
        PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op", userGesture: true, gestureEvent: 1)
    }

    private var script: PageCallContext {
        PageCallContext(page: "cmux.settings", origin: "page", confirmed: false, opid: "op")
    }

    @Test func theStateAndCheckAreAcpmuxsAsIs() async throws {
        let daemon = Daemon()
        let dictation = make(daemon, Keys())
        let state = try await dictation.call(SettingsDictation.op, params: ["action": "state"], context: script)
        #expect(state["engine"]?.stringValue == "openai")
        #expect(state["keyAccount"]?.stringValue == "openai@https://api.openai.com")
        let check = try await dictation.call(SettingsDictation.op, params: ["action": "check"], context: script)
        #expect(check["ok"]?.boolValue == false)
        #expect(check["error"]?["code"]?.stringValue == "key_missing")
        #expect(daemon.methods.withLock { $0 } == ["_acpmux/voice/state", "_acpmux/voice/check"])
    }

    @Test func aPastedKeyGoesToTheKeychainAtTheStatesAccount() async throws {
        let daemon = Daemon()
        let keys = Keys()
        let dictation = make(daemon, keys)
        let state = try await dictation.call(SettingsDictation.op, params: ["action": "setKey", "key": "sk-test-123\n"], context: click)
        #expect(await keys.items == ["cmux-voice-key/openai@https://api.openai.com": "sk-test-123"])
        #expect(state["engine"]?.stringValue == "openai", "a fresh state comes back")
        #expect(daemon.methods.withLock { $0 } == ["_acpmux/voice/state", "_acpmux/voice/state"])
        // The key is in no answer.
        #expect(!String(describing: state).contains("sk-test-123"))
    }

    @Test func setKeyAndRemoveKeyNeedAClick() async throws {
        let keys = Keys()
        let dictation = make(Daemon(), keys)
        for params: JSONValue in [["action": "setKey", "key": "sk-test"], ["action": "removeKey"]] {
            await #expect(throws: PageError.self) {
                _ = try await dictation.call(SettingsDictation.op, params: params, context: script)
            }
        }
        #expect(await keys.items.isEmpty)
        #expect(await keys.deleted.isEmpty)
    }

    @Test(arguments: ["", "two words", "tab\there", "naïve"])
    func aKeyThatIsNotOneWordIsRefused(_ key: String) async throws {
        let keys = Keys()
        let dictation = make(Daemon(), keys)
        await #expect(throws: PageError.self) {
            _ = try await dictation.call(SettingsDictation.op, params: ["action": "setKey", "key": .string(key)], context: click)
        }
        #expect(await keys.items.isEmpty)
    }

    @Test func noAccountRefusesAKey() async throws {
        let daemon = Daemon()
        daemon.account.withLock { $0 = nil }
        let keys = Keys()
        let dictation = make(daemon, keys)
        await #expect(throws: PageError.self) {
            _ = try await dictation.call(SettingsDictation.op, params: ["action": "setKey", "key": "sk-test"], context: click)
        }
        #expect(await keys.items.isEmpty)
    }

    @Test func anotherKeychainServiceIsRefused() async throws {
        let daemon = Daemon()
        daemon.service.withLock { $0 = "cmux-model-key" }
        let keys = Keys()
        let dictation = make(daemon, keys)
        await #expect(throws: PageError.self) {
            _ = try await dictation.call(SettingsDictation.op, params: ["action": "setKey", "key": "sk-test"], context: click)
        }
        #expect(await keys.items.isEmpty)
    }

    @Test func removeKeyDeletesTheStatesItem() async throws {
        let keys = Keys()
        let dictation = make(Daemon(), keys)
        _ = try await dictation.call(SettingsDictation.op, params: ["action": "setKey", "key": "sk-test"], context: click)
        let state = try await dictation.call(SettingsDictation.op, params: ["action": "removeKey"], context: click)
        #expect(await keys.items.isEmpty)
        #expect(await keys.deleted == ["cmux-voice-key/openai@https://api.openai.com"])
        #expect(state["engine"]?.stringValue == "openai")
    }

    @Test func anUnknownActionIsRefused() async throws {
        let dictation = make(Daemon(), Keys())
        await #expect(throws: PageError.self) {
            _ = try await dictation.call(SettingsDictation.op, params: ["action": "nope"], context: click)
        }
        await #expect(throws: PageError.self) {
            _ = try await dictation.call("cmux.settings.dictation.state", params: ["action": "state"], context: click)
        }
    }
}
