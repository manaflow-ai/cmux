public import CmuxNextDaemon
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

    /// What the machine session carries: the variable, the connection's id and the token's expiry.
    public var launch: AgentSessionAttachClient.LaunchCredential {
        AgentSessionAttachClient.LaunchCredential(env: env, connection: connectionID, expiresAt: expiresAt)
    }

    public var description: String { "CloudAgentCredential(\(connectionID), \(kind), \(env.keys.sorted().joined(separator: ",")))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["connectionID": connectionID, "kind": kind, "names": env.keys.sorted()], displayStyle: .struct)
    }
}

/// The owner's model credentials for Cloud chats (model-connections.md "Revision 2", lane F): the one
/// entry point that reads a connection's credential from this Mac's acpmux, the credential a new
/// Cloud chat's start sends (the connection its Cloud start chose rides in the chat's seed,
/// `AgentPaneSeed.cloudConnection`), and the ``refresher`` that keeps each live ChatGPT plan agent's
/// token fresh on its machine: the chats this app started, and the ones it attaches again after a
/// relaunch or a reconnect (``reattach(chat:machine:status:push:)``), whose credential the machine's
/// acpmux may have lost in a restart.
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
    /// Whether a machine's chat runs on the owner's credential (`agent-session-credential-status`).
    public typealias Status = @Sendable () async throws -> AgentSessionAttachClient.CredentialStatus?

    /// Set by the app once it has an acpmux; nil reads nothing.
    public var read: Read?
    /// The refresher's id of each chat it keeps fresh, by machine and chat tab key.
    private var tracked: [ChatKey: UUID] = [:]
    /// The chats whose status a reattach reads now.
    private var reattaching: Set<ChatKey> = []
    /// Each chat's reattach while it runs.
    private var reattaches: [ChatKey: Task<Void, Never>] = [:]

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

    /// The credential a chat's start sends, read now: nil only when its Cloud start chose no
    /// connection (`connection`, the seed's: a team key, or the machine's own route). A chosen
    /// connection never falls back to the machine's own route: one that cannot be read throws
    /// `refusal`, and one of another family than the agent it starts (the person switched agent
    /// after the choice; `family`: ``CloudSetup/family(of:)``) throws `mismatch`.
    public func launchCredential(connection: String?, family: String?, refusal: @autoclosure () -> any Error,
                                 mismatch: @autoclosure () -> any Error) async throws -> CloudAgentCredential? {
        guard let connection else { return nil }
        let credential: CloudAgentCredential
        do { credential = try await self.credential(forConnection: connection) } catch { throw refusal() }
        guard family == nil || credential.family == family else { throw mismatch() }
        return credential
    }

    /// The chat tab `chat` on `machine` started on `credential`: a ChatGPT plan token is kept fresh
    /// on that machine through `push` (``CloudAgentCredentialRefresher/track(_:delivered:push:)``).
    @discardableResult
    public func started(chat: String, machine: String, on credential: CloudAgentCredential,
                        push: @escaping CloudAgentCredentialRefresher.Push) -> UUID? {
        keep(ChatKey(machine: machine, chat: chat), refresher.track(credential, push: push))
    }

    /// The page of chat tab `chat` on `machine` connected to it (each connection: opening the tab,
    /// a reconnect after the machine or its acpmux restarted, which ends every attachment): its
    /// machine says whether it runs on the owner's credential (`status`). One its acpmux lost (a
    /// restart keeps only the reference) is read again from this Mac and sent at once (`push`),
    /// whatever its kind (a ChatGPT plan token, a Claude token, an API key), so the chat goes on
    /// rather than waiting with "needs your Mac"; a ChatGPT plan token is then kept fresh from the
    /// expiry the machine has. One status read at a time per chat; a chat already kept fresh whose
    /// machine still holds its credential reads nothing more. A chat on the machine's own route, or
    /// one whose connection this Mac no longer has, is left as it is (the chat says it needs this
    /// Mac to reconnect).
    public func reattach(chat: String, machine: String, status: @escaping Status, push: @escaping CloudAgentCredentialRefresher.Push) {
        let key = ChatKey(machine: machine, chat: chat)
        guard !reattaching.contains(key) else { return }
        reattaching.insert(key)
        // task-owner: this chat's reattach (one status read, at most one credential read and one push); cancelled by machineRemoved
        reattaches[key] = Task { [weak self] in
            let found = try? await status()
            await self?.reattached(key, found.flatMap { $0 }, push: push)
        }
    }

    private func reattached(_ key: ChatKey, _ status: AgentSessionAttachClient.CredentialStatus?, push: @escaping CloudAgentCredentialRefresher.Push) async {
        defer { reattaching.remove(key); reattaches[key] = nil }
        guard let status, let connection = status.connection else { return }
        let kept = tracked[key].map(refresher.isTracked) ?? false
        guard status.lost || (status.chatgpt && !kept) else { return }
        guard let credential = try? await credential(forConnection: connection) else { return }
        var delivered = status.expiresAt ?? credential.expiresAt
        if status.lost {
            guard await push(credential.launch) == .delivered else { return }
            delivered = credential.expiresAt
        }
        keep(key, refresher.track(credential, delivered: delivered, push: push))
    }

    @discardableResult
    private func keep(_ key: ChatKey, _ id: UUID?) -> UUID? {
        if let old = tracked.removeValue(forKey: key) { refresher.untrack(old) }
        if let id { tracked[key] = id }
        return id
    }

    /// The machine is gone (deleted, or no longer the account's): its chats are no longer refreshed.
    public func machineRemoved(_ machine: String) {
        for key in tracked.keys where key.machine == machine {
            if let id = tracked.removeValue(forKey: key) { refresher.untrack(id) }
        }
        for key in reattaches.keys where key.machine == machine { reattaches.removeValue(forKey: key)?.cancel(); reattaching.remove(key) }
    }

    /// How many chats are kept fresh now.
    public var trackedChats: Int { tracked.values.filter(refresher.isTracked).count }

    /// Waits for every reattach that runs now (tests).
    func reattachesSettled() async {
        for task in Array(reattaches.values) { await task.value }
    }
}

extension CloudAgentCredentials {
    /// ``reattach(chat:machine:status:push:)`` for the chat on tab `surface` of a Cloud machine's
    /// daemon, over the owner answer of its link (nil: not the owner's machine, nothing is read).
    public func reattach(chat: String, machine: String, surface: UInt64, ownerLink: AgentSessionAttachClient.OwnerLink?,
                         reconnect: AgentSessionAttachClient.Reconnect?, endpoint: @escaping AgentSessionAttachClient.EndpointProvider) {
        guard let ownerLink else { return }
        reattach(chat: chat, machine: machine, status: {
            let client = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
            let status: Result<AgentSessionAttachClient.CredentialStatus?, any Error>
            do { status = .success(try await client.credentialStatus(ownerLink: ownerLink)) } catch { status = .failure(error) }
            await client.close()
            return try status.get()
        }, push: CloudAgentCredentialRefresher.machinePush(surface: surface, ownerLink: ownerLink, reconnect: reconnect, endpoint: endpoint))
    }
}
