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
    /// `claude-token`, `api-key` or `chatgpt-plan`.
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

    /// A ChatGPT plan token the Mac pushes again before it expires.
    public var refreshes: Bool { kind == Self.chatGPTPlan && expiresAt != nil }

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

    /// The credential the chat's start sends, read now; nil when no connection was chosen for it. A
    /// chosen connection that cannot be read throws: the start says so instead of using another route.
    public func launchCredential(chat: String, machine: String) async throws -> CloudAgentCredential? {
        guard let id = connection(chat: chat, machine: machine) else { return nil }
        return try await credential(forConnection: id)
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
