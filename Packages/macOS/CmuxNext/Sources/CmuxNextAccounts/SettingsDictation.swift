public import CmuxNextAgentPane
import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextWakeups
public import Foundation

/// Where a dictation provider's API key goes on this Mac: the Keychain item acpmux reads at each
/// `_acpmux/voice/*` call (service `cmux-voice-key`, account `<provider>@<origin>`, both named by
/// `_acpmux/voice/state`), so a key is only ever sent to the origin it was saved for.
public protocol VoiceKeyStoring: Sendable {
    /// Stores KEY as the item SERVICE/ACCOUNT, replacing one already there.
    func store(_ key: String, service: String, account: String) async throws
    /// Removes the item SERVICE/ACCOUNT, if there is one.
    func delete(service: String, account: String) async
}

/// The login Keychain through `/usr/bin/security`, as ``KeychainModelKeyStore`` stores a model key:
/// the key goes only to the tool's standard input (`security -i`), never its arguments, and its output
/// (which can echo the line) is dropped. `-U` updates an item in place.
public struct KeychainVoiceKeyStore: VoiceKeyStoring {
    public init() {}

    public func store(_ key: String, service: String, account: String) async throws {
        let line = "add-generic-password -U -s \(KeychainModelKeyStore.quoted(service)) -a \(KeychainModelKeyStore.quoted(account)) "
            + "-l \(KeychainModelKeyStore.quoted("cmux dictation API key")) -w \(KeychainModelKeyStore.quoted(key))\n"
        let ran = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"), ["-i"],
                                                              input: Data(line.utf8), errorOutput: .discard, timeout: .seconds(30), onCancel: .finish))
        guard ran.succeeded else { throw PageError(code: "cmux.dictation.keychain", message: "the key could not be stored in the Keychain") }
    }

    public func delete(service: String, account: String) async {
        _ = try? await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"),
                                                         ["delete-generic-password", "-s", service, "-a", account],
                                                         errorOutput: .discard, timeout: .seconds(30)))
    }
}

/// The Settings page's `cmux.settings.dictation.run` (webviews/src/pages/settings/ops.ts `DictationRun`):
/// the dictation engine's state, its API key and its connection check, for the three
/// `agentPane.dictationEngine*` settings. acpmux (`_acpmux/voice/*`, crate cmux-voice) reads the settings
/// and the key itself; this stores the key where acpmux's state says and asks acpmux for the rest.
///
/// - `{action: "state"}`: `_acpmux/voice/state` as is.
/// - `{action: "setKey", key}`: a click in the page only; the key goes into the Keychain at the
///   `keyService`/`keyAccount` a fresh state names, and the new state comes back. The key never reaches
///   page state, a log, a file, an argument or a URL.
/// - `{action: "removeKey"}`: a click in the page only; removes that item, answers the new state.
/// - `{action: "check"}`: `_acpmux/voice/check` as is (no audio is sent).
@MainActor
public final class SettingsDictation: PageProvider {
    /// The one op this part serves.
    public static let op = "cmux.settings.dictation.run"
    /// The one Keychain service acpmux reads a dictation key from; a state naming another is refused.
    nonisolated static let keyService = "cmux-voice-key"

    private let environment: @MainActor () -> AcpmuxEnvironment?
    private let daemonCall: (@Sendable (AcpmuxEnvironment, AcpmuxHarnessMethod, [String: any Sendable]) async throws -> Data)?
    private let keys: any VoiceKeyStoring
    private let onKeyChanged: @MainActor (String, Bool) -> Void

    /// - Parameters:
    ///   - environment: the local acpmux.
    ///   - call: a test's stand-in for the daemon; nil calls it (``AcpmuxEnvironment/harness(_:params:)``).
    ///   - keys: the Keychain.
    public init(environment: @escaping @MainActor () -> AcpmuxEnvironment?,
                call: (@Sendable (AcpmuxEnvironment, AcpmuxHarnessMethod, [String: any Sendable]) async throws -> Data)? = nil,
                keys: any VoiceKeyStoring = KeychainVoiceKeyStore(),
                onKeyChanged: @escaping @MainActor (String, Bool) -> Void = { _, _ in }) {
        self.environment = environment
        daemonCall = call
        self.keys = keys
        self.onKeyChanged = onKeyChanged
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard op == Self.op else { throw PageError.unknownOp(op) }
        switch params["action"]?.stringValue {
        case "state":
            return try await daemon(.voiceState)
        case "check":
            return try await daemon(.voiceCheck)
        case "setKey":
            try Self.requirePerson(context)
            let key = (params["key"]?.stringValue ?? "").trimmingCharacters(in: .newlines)
            guard SettingsModels.isOneWord(key) else {
                throw PageError.invalidParams("setKey needs a key of printable characters with no spaces")
            }
            let (service, account) = try Self.keyItem(try await daemon(.voiceState))
            guard let account else {
                throw PageError(code: "cmux.dictation.no_key_account",
                                message: "this dictation engine takes no key here; pick one that does, or set its server URL first")
            }
            try await keys.store(key, service: service, account: account)
            onKeyChanged(account, false)
            return try await daemon(.voiceState)
        case "removeKey":
            try Self.requirePerson(context)
            let (service, account) = try Self.keyItem(try await daemon(.voiceState))
            if let account {
                await keys.delete(service: service, account: account)
                onKeyChanged(account, true)
            }
            return try await daemon(.voiceState)
        default:
            throw PageError.invalidParams("cmux.settings.dictation.run needs an action: state, setKey, removeKey or check")
        }
    }

    /// The Keychain item a state names: its service (only ``keyService``) and account (nil when the
    /// engine takes no key or has no URL yet). An account must be one printable word, as
    /// `<provider>@<origin>` is, so it cannot break the `security -i` line.
    nonisolated static func keyItem(_ state: JSONValue) throws -> (service: String, account: String?) {
        let service = state["keyService"]?.stringValue ?? keyService
        guard service == keyService else {
            throw PageError(code: "cmux.dictation.bad_state", message: "acpmux named an unexpected Keychain service")
        }
        guard let account = state["keyAccount"]?.stringValue, !account.isEmpty else { return (service, nil) }
        guard SettingsModels.isOneWord(account) else {
            throw PageError(code: "cmux.dictation.bad_state", message: "acpmux named an unexpected Keychain account")
        }
        return (service, account)
    }

    private static func requirePerson(_ context: PageCallContext) throws {
        guard context.userGesture || context.isConfirmedUser else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: RefusalStrings.personOnlyFromPage)
        }
    }

    /// One daemon call, its answer as the page's JSON: the test's stand-in, else the local socket.
    private func daemon(_ method: AcpmuxHarnessMethod) async throws -> JSONValue {
        guard let environment = environment() else { throw PageError(code: "cmux.page.unavailable", message: "no acpmux") }
        let data: Data
        do {
            if let daemonCall {
                data = try await daemonCall(environment, method, [:])
            } else {
                data = try await environment.harness(method)
            }
        } catch let error as AcpmuxRPCError {
            throw PageError(code: "cmux.dictation.\(error.name ?? (error.isMethodMissing ? "unsupported" : "failed"))", message: error.message)
        }
        return try JSONValue.parse(data)
    }
}
