import CmuxNextDaemon
public import Foundation

/// One model connection's credential as this Mac's acpmux gives it for a Cloud chat
/// (`_acpmux/connections/credential {id}` -> `{family, kind, env, expires_at}`,
/// cmux-tui/docs/model-connections.md "Revision 2"): the variables the machine's agent launches
/// with, straight to the provider. Its descriptions and mirror name the variables, never a value.
public struct CloudAgentCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The kind whose access token expires and is refreshed while the app runs.
    public static let chatGPTPlan = "chatgpt-plan"

    public let connectionID: String
    /// `claude` or `codex`.
    public let family: String
    /// `claude-token`, `api-key`, `chatgpt-plan`, or `codex-login` / `subscription` (a Codex CLI
    /// ChatGPT login's access token, cmux#45774).
    public let kind: String
    public let env: [String: String]
    public let expiresAt: Date?

    public init(connectionID: String, family: String, kind: String, env: [String: String], expiresAt: Date?) {
        (self.connectionID, self.family, self.kind, self.env, self.expiresAt) = (connectionID, family, kind, env, expiresAt)
    }

    /// The reply of `_acpmux/connections/credential` for `connectionID`; nil for any other shape.
    public init?(connectionID: String, reply: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let family = object["family"] as? String, let kind = object["kind"] as? String,
              let env = object["env"] as? [String: String], !env.isEmpty else { return nil }
        let expires = (object["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        self.init(connectionID: connectionID, family: family, kind: kind, env: env, expiresAt: expires)
    }

    /// A token the Mac pushes again before it expires: every credential acpmux gives an expiry (a
    /// ChatGPT plan token, a Codex CLI login's access token); a Claude token or an API key has none.
    public var refreshes: Bool { expiresAt != nil }

    /// The Mac's Codex CLI login's access token (`CMUX_CODEX_ACCESS_TOKEN`), which a machine daemon from before
    /// `agent-session-start-codex-login-credential-v1` refuses (``AgentSessionAttachClient/takesCredential(_:servesCodexLogin:)``).
    public var isCodexLogin: Bool { !AgentSessionAttachClient.takesCredential(env, servesCodexLogin: false) }

    public var description: String { "CloudAgentCredential(\(connectionID), \(kind), \(env.keys.sorted().joined(separator: ",")))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["connectionID": connectionID, "kind": kind, "names": env.keys.sorted()], displayStyle: .struct)
    }
}

/// The owner's model credentials for Cloud chats (model-connections.md "Revision 2", lane F): the one
/// entry point that reads a connection's credential from this Mac's acpmux, the connection each new
/// Cloud chat starts on (the Cloud start picks it, ``use(connection:chat:machine:)``), and the
/// ``refresher`` that keeps each live ChatGPT plan agent's token fresh on its machine.
///
/// Nothing here writes a credential anywhere: it is read when a start or a refresh needs it, sent
/// over the machine session, and dropped.
@MainActor
public final class CloudAgentCredentials {
    public enum Failure: Error, Equatable {
        /// This Mac's acpmux did not give the connection's credential (not running, not the person,
        /// no such connection, or a connection that does not serve Cloud).
        case unavailable(connection: String)
        /// The chat's connection is the Mac's Codex CLI login, its machine's daemon does not take it, and no other
        /// connection of this Mac serves the chat's agent on Cloud (``launchCredential(chat:machine:harness:model:takesCodexLogin:)``).
        case codexLoginUnsupported
    }

    /// One `_acpmux/connections/credential {id}` on this Mac's acpmux, as the person: its result.
    public typealias Read = @MainActor (_ connectionID: String) async throws -> Data

    /// Set by the app once it has an acpmux; nil reads nothing.
    public var read: Read?
    /// The connection each new Cloud chat starts on, by machine and chat tab key.
    private var chosen: [ChatKey: String] = [:]

    private struct ChatKey: Hashable { let machine: String, chat: String }

    public private(set) lazy var refresher = CloudAgentCredentialRefresher { [weak self] id in
        guard let self else { throw Failure.unavailable(connection: id) }
        return try await self.credential(forConnection: id)
    }

    public init(read: Read? = nil) { self.read = read }

    /// The credential of connection `id`, read now (a ChatGPT plan token fresh, at least ten minutes left).
    public func credential(forConnection id: String) async throws -> CloudAgentCredential {
        guard let read else { throw Failure.unavailable(connection: id) }
        guard let credential = CloudAgentCredential(connectionID: id, reply: try await read(id)) else {
            throw Failure.unavailable(connection: id)
        }
        return credential
    }

    /// The Cloud start's choice for the chat tab `chat` on `machine`: its agent launches on connection
    /// `id` (nil: the machine's own route). Read once, at the chat's start on that machine.
    public func use(connection id: String?, chat: String, machine: String) {
        chosen[ChatKey(machine: machine, chat: chat)] = id
    }

    /// The chat's tab got the key `key` on `machine` (not the one its start planned): its choice follows.
    public func move(chat: String, to key: String, machine: String) {
        guard let id = chosen.removeValue(forKey: ChatKey(machine: machine, chat: chat)) else { return }
        chosen[ChatKey(machine: machine, chat: key)] = id
    }

    /// The connection chosen for `chat` on `machine`, if any.
    public func connection(chat: String, machine: String) -> String? {
        chosen[ChatKey(machine: machine, chat: chat)]
    }

    /// Cloud first use's rule, set by the app (``CloudSetup/choose(harness:model:account:)``): the connection a Cloud
    /// chat that no Cloud start chose for launches on (`cmux chat --on vm`, `cmux cloud start-session`, a new chat
    /// opened in a machine's workspace). Nil: such a chat starts on the machine's own route.
    public var setup: CloudSetup?

    /// The credential the chat's start sends, read now. A chosen connection that cannot be read throws:
    /// the start says so instead of using another route. With no choice, the connection Cloud first use
    /// picks for `harness` (``setup``); nil when none serves it or it cannot be read (the machine's own route).
    ///
    /// `takesCodexLogin` false: the machine's daemon does not take the Mac's Codex CLI login
    /// (`agent-session-start-codex-login-credential-v1`). A credential that is one is replaced by the next connection
    /// serving the chat's agent on Cloud that is not (``CloudSetup/otherThanCodexLogin(harness:model:account:)``); with
    /// none this throws ``Failure/codexLoginUnsupported``, and nothing is sent.
    public func launchCredential(chat: String, machine: String, harness: String? = nil, model: String? = nil,
                                 takesCodexLogin: Bool = true) async throws -> CloudAgentCredential? {
        let chosen: CloudAgentCredential?
        if let id = connection(chat: chat, machine: machine) {
            chosen = try await credential(forConnection: id)
        } else if let picked = await setup?.choose(harness: harness, model: model, account: nil).connectionID {
            chosen = try? await credential(forConnection: picked)
        } else {
            chosen = nil
        }
        guard let chosen, chosen.isCodexLogin, !takesCodexLogin else { return chosen }
        guard let other = await setup?.otherThanCodexLogin(harness: harness ?? chosen.family, model: model, account: nil),
              let replacement = try? await credential(forConnection: other), !replacement.isCodexLogin else { throw Failure.codexLoginUnsupported }
        return replacement
    }

    /// A chat's start, `send`, with `credential`'s env (``launchCredential(chat:machine:harness:model:takesCodexLogin:)``):
    /// its result and the credential it went with. When the machine's daemon does not take the Mac's Codex CLI login
    /// (`AgentSessionAttachClient.codexLoginUnsupported`: refused before it was sent, cmux#45774), it is sent once more on
    /// the next connection of this Mac serving the agent on Cloud; with none, the refusal stands (the start coordinator
    /// then updates the machine and tries once more, `AgentRemoteStartRefusal.olderDaemonCodes`).
    public static func sending<T>(_ credential: CloudAgentCredential?, with credentials: CloudAgentCredentials?, chat: String, machine: String,
                                  harness: String?, model: String?,
                                  _ send: ([String: String]?) async throws -> T) async -> (Result<T, any Error>, CloudAgentCredential?) {
        let first: Result<T, any Error>
        do { first = .success(try await send(credential?.env)) } catch { first = .failure(error) }
        guard case .failure(let error as AgentSessionAttachError) = first, error.code == AgentSessionAttachClient.codexLoginUnsupported,
              let other = try? await credentials?.launchCredential(chat: chat, machine: machine, harness: harness, model: model, takesCodexLogin: false) else {
            return (first, credential)
        }
        let again: Result<T, any Error>
        do { again = .success(try await send(other.env)) } catch { again = .failure(error) }
        return (again, other)
    }

    /// The chat started on `credential`: its choice is spent, and a ChatGPT plan token is kept fresh
    /// on that machine through `push` (``CloudAgentCredentialRefresher/track(_:push:)``).
    @discardableResult
    public func started(chat: String, machine: String, on credential: CloudAgentCredential,
                        push: @escaping CloudAgentCredentialRefresher.Push) -> UUID? {
        chosen[ChatKey(machine: machine, chat: chat)] = nil
        return refresher.track(credential, push: push)
    }
}
