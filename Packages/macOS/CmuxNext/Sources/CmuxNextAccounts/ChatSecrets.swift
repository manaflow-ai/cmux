public import CmuxNextActions
public import CmuxNextAgentPane
public import CmuxNextCloud
import CmuxNextDaemonService
import CmuxNextWakeups
public import Foundation

/// The secrets the person names (`--names A,B`, `--repo OWNER/NAME`) and their values from this Mac's
/// Keychain (`cmux cloud secret set`), read for one delivery and never kept, written or logged here.
/// Moved from CmuxNextApp (CloudHandlers+OwnMachineSecrets): a machine's delivery and a chat's share them.
public struct KeychainSecrets: Sendable {
    public init() {}

    /// `--names A,B`: nil when not given; refused when bare, empty or not secret names. Each once, in order.
    public func names(_ invocation: ActionInvocation) throws -> [String]? {
        guard let value = invocation["names"] else { return nil }
        guard let text = value.stringValue else { throw ActionFailure(message: CloudStrings.secretNamesInvalid("--names")) }
        let names = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !names.isEmpty, names.allSatisfy({ CloudMachineSecrets.isName($0) }) else {
            throw ActionFailure(message: CloudStrings.secretNamesInvalid(text))
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// `--repo OWNER/NAME`: nil when not given. A bare `--repo` (no value) arrives as `true`: refused,
    /// never taken for the global values.
    public func repo(_ invocation: ActionInvocation) throws -> String? {
        guard let value = invocation["repo"] else { return nil }
        guard let text = value.stringValue else { throw ActionFailure(message: CloudStrings.secretRepoInvalid("--repo")) }
        guard let scope = CloudMachineSecrets.repoScope(text) else { throw ActionFailure(message: CloudStrings.secretRepoInvalid(text)) }
        return scope
    }

    /// The values of `items` from this Mac's Keychain, each one line as `cmux cloud secret set` stores them.
    public func values(_ items: [CloudMachineSecrets.Item]) async throws -> [(name: String, value: String)] {
        var values: [(name: String, value: String)] = []
        for item in items {
            let ran = try await AsyncProcess().run(ProcessRequest(URL(fileURLWithPath: "/usr/bin/security"),
                ["find-generic-password", "-s", CloudMachineSecrets.service, "-a", item.account, "-w"], timeout: .seconds(30)))
            guard ran.succeeded else { throw ActionFailure(message: CloudStrings.secretUnreadable(item.name)) }
            let value = String(ran.text.dropLast(ran.text.hasSuffix("\n") ? 1 : 0))
            // One line, no NUL, as `cmux cloud secret set` stores it: an item made some other way never
            // turns into extra records on the machine.
            guard CloudMachineSecrets.isValue(value) else { throw ActionFailure(message: CloudStrings.secretUnreadable(item.name)) }
            values.append((item.name, value))
        }
        return values
    }
}

/// One chat's secrets in this Mac's acpmux (hq RFD 0211, VM item 4: per chat, short-lived, never on disk).
/// Leo, 2026-11-25: "security/sandboxing... how will that work? what about if someone wants to lock
/// down a vm? lock down their app?"
///
/// The values go over the person's own line (`AcpmuxPersonLine`; acpmux takes `_acpmux/chat_secrets_set`
/// only from it) to acpmux, which keeps them in its memory for that chat with its TTL (one hour), zeroes
/// them on drop and puts them in that chat's agent environment and no other's (acpmux `chat_secrets.rs`).
/// A chat on another machine is refused there: a chat secret never crosses a daemon link.
@MainActor
public struct AcpmuxChatSecrets {
    public let environment: AcpmuxEnvironment

    public init(environment: AcpmuxEnvironment) { self.environment = environment }

    /// Gives `values` to chat `session`; acpmux's `applied` word for the agent's restart.
    /// A refusal carries acpmux's own words (a name it refused, a chat on another machine), never a value.
    public func give(_ values: [(name: String, value: String)], to session: String) async throws -> String {
        guard let line = await AcpmuxPersonLine.open(environment) else { throw ActionFailure(message: CloudStrings.secretsNotDelivered("acpmux")) }
        defer { line.close() }
        guard line.isPerson else { throw ActionFailure(message: CloudStrings.secretsNotDelivered(line.notPersonReason?.description ?? "acpmux")) }
        guard let reply = await line.call("_acpmux/chat_secrets_set", Self.params(session: session, values: values)) else {
            throw ActionFailure(message: CloudStrings.secretsNotDelivered(line.lastError ?? "acpmux"))
        }
        return reply["applied"] as? String ?? ""
    }

    /// The request acpmux `server/secrets.rs` reads: `{sessionId, secrets: {NAME: value}}`, the TTL its own.
    public nonisolated static func params(session: String, values: [(name: String, value: String)]) -> [String: Any] {
        ["sessionId": session, "secrets": Dictionary(values.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })]
    }
}
