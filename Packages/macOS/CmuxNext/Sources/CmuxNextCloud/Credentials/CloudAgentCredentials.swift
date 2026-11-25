public import Foundation
public import CmuxNextDaemon

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
    /// The connection kind, such as `api-key` or `chatgpt-plan`.
    public let kind: String
    public let env: [String: String]
    public let expiresAt: Date?
    public let harness: String?
    public let model: String?
    public let endpoint: AgentSessionAttachClient.LaunchEndpoint?

    public init(connectionID: String, family: String, kind: String, env: [String: String], expiresAt: Date?,
                harness: String? = nil, model: String? = nil, endpoint: AgentSessionAttachClient.LaunchEndpoint? = nil) {
        (self.connectionID, self.family, self.kind, self.env, self.expiresAt) = (connectionID, family, kind, env, expiresAt)
        (self.harness, self.model, self.endpoint) = (harness, model, endpoint)
    }

    /// The reply of `_acpmux/connections/credential` for `connectionID`; nil for any other shape.
    public init?(connectionID: String, reply: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let family = object["family"] as? String, let kind = object["kind"] as? String,
              let env = object["env"] as? [String: String], !env.isEmpty else { return nil }
        let expires = (object["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        if let metadata = object["endpoint"] {
            guard kind == "endpoint", let harness = object["harness"] as? String,
                  let model = object["model"] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.fragmentsAllowed]),
                  let endpoint = try? JSONDecoder().decode(AgentSessionAttachClient.LaunchEndpoint.self, from: data),
                  !endpoint.models.isEmpty else { return nil }
            switch endpoint.kind {
            case .anthropic:
                guard harness == "claude", Set(env.keys) == ["ANTHROPIC_AUTH_TOKEN"] else { return nil }
            case .openAI:
                guard harness == "opencode", Set(env.keys) == ["CMUX_BYO_API_KEY"] else { return nil }
            }
            self.init(connectionID: connectionID, family: family, kind: kind, env: env, expiresAt: expires,
                      harness: harness, model: model, endpoint: endpoint)
        } else {
            guard kind != "endpoint" else { return nil }
            self.init(connectionID: connectionID, family: family, kind: kind, env: env, expiresAt: expires)
        }
    }

    /// A ChatGPT plan token the Mac pushes again before it expires.
    public var refreshes: Bool { (kind == Self.chatGPTPlan || kind == "grok-plan" || kind == "endpoint") && expiresAt != nil }

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
        case refused(reason: String)

        public var requiresSignIn: Bool {
            guard case .refused(let reason) = self else { return false }
            return [".reauth_required", ".signed_out"].contains { reason.hasSuffix($0) }
        }
    }

    /// One `_acpmux/connections/credential {id}` on this Mac's acpmux, as the person: its result.
    public typealias Read = @MainActor (_ connectionID: String) async throws -> Data

    /// Set by the app once it has an acpmux; nil reads nothing.
    public var read: Read?
    public var readForModel: (@MainActor (String, String) async throws -> Data)?
    /// The connection each new Cloud chat starts on, by machine and chat tab key.
    private var chosen: [ChatKey: Selection] = [:]
    private var tracked: [ChatKey: UUID] = [:]

    private struct Selection {
        let connection: String?
        let harness: String?
    }

    private struct ChatKey: Hashable { let machine: String, chat: String }

    private struct KeyDelivery {
        let id = UUID()
        let connection: String
        let harness: String
        let model: String?
        let originalKind: String
        let replace: CloudAgentCredentialRefresher.Replace
    }

    /// Reads enabled Cloud connections. Nil means the local connection list is unavailable.
    public var readCredentialConnections: (@MainActor () async -> Set<String>?)?
    /// Subscribes to local connection changes while a key-backed Cloud chat is tracked.
    public var watchCredentialConnections: (@MainActor () async -> AsyncStream<Void>?)?
    private var keyWatch: Task<Void, Never>?
    private var keyDeliveries: [ChatKey: KeyDelivery] = [:]
    private(set) var keySync: Task<Void, Never>?
    private var keyChangesPending = false

    /// Reconcile an owner's key-backed launches after a route change or a guest reconnect.
    /// Only confirmed removal sends an empty environment, which the guest treats as revocation.
    public func credentialConnectionsChanged() {
        guard !keyDeliveries.isEmpty else { return }
        startKeyWatch()
        queueKeySync()
    }

    /// A reattached chat may have a new guest acpmux behind the same machine daemon.
    public func restoreTrackedConnection(chat: String, machine: String) async {
        guard keyDeliveries[ChatKey(machine: machine, chat: chat)] != nil else { return }
        credentialConnectionsChanged()
        await keySync?.value
    }

    private func startKeyWatch() {
        guard keyWatch == nil, let watchCredentialConnections else { return }
        // task-owner: keyWatch, until acpmux closes its watch or no key-backed chat remains.
        keyWatch = Task { [weak self] in
            if let changes = await watchCredentialConnections() {
                for await _ in changes { self?.queueKeySync() }
            }
            self?.keyWatch = nil
        }
    }

    private func queueKeySync() {
        keyChangesPending = true
        guard keySync == nil else { return }
        // task-owner: keySync; changes coalesce into this worker and send in order.
        keySync = Task { [weak self] in
            guard let self else { return }
            await self.syncKeys()
        }
    }

    private func syncKeys() async {
        defer {
            keySync = nil
            if keyDeliveries.isEmpty { keyWatch?.cancel() }
        }
        while keyChangesPending {
            keyChangesPending = false
            guard let ids = await readCredentialConnections?() else { continue }
            let groups = Dictionary(grouping: keyDeliveries.keys, by: { keyDeliveries[$0]?.connection })
            for (connection, chats) in groups {
                guard let connection else { continue }
                for chat in chats {
                    guard let delivery = keyDeliveries[chat], delivery.connection == connection else { continue }
                    let replacement: CloudAgentCredential?
                    if ids.contains(connection) {
                        guard let credential = try? await credential(forConnection: connection, model: delivery.model, harness: delivery.harness),
                              credential.kind == delivery.originalKind else { continue }
                        replacement = credential
                    } else {
                        replacement = nil
                    }
                    let result = await delivery.replace(replacement)
                    if keyDeliveries[chat]?.id == delivery.id && (result == .gone || result == .delivered && replacement == nil) {
                        keyDeliveries[chat] = nil
                    }
                }
            }
        }
    }

    public private(set) lazy var refresher = CloudAgentCredentialRefresher { [weak self] id in
        guard let self else { throw Failure.unavailable(connection: id) }
        return try await self.credential(forConnection: id)
    }

    public init(read: Read? = nil) { self.read = read }

    /// The credential of connection `id`, read now for the selected harness and model.
    public func credential(forConnection id: String, model: String? = nil, harness: String? = nil) async throws -> CloudAgentCredential {
        let reply: Data
        if let model = model ?? (harness == "openrouter" ? "openrouter/default" : nil), let readForModel {
            reply = try await readForModel(id, model)
        } else if let read {
            reply = try await read(id)
        } else {
            throw Failure.unavailable(connection: id)
        }
        guard let credential = CloudAgentCredential(connectionID: id, reply: reply) else {
            throw Failure.unavailable(connection: id)
        }
        return credential
    }

    /// The Cloud start's choice for the chat tab `chat` on `machine`: its agent launches on connection
    /// `id` (nil: the machine's own route). Read once, at the chat's start on that machine.
    public func use(connection id: String?, chat: String, machine: String, harness: String? = nil, useMachineLogin: Bool = false) {
        chosen[ChatKey(machine: machine, chat: chat)] = id != nil || useMachineLogin ? Selection(connection: id, harness: harness) : nil
    }

    /// The chat's tab got the key `key` on `machine` (not the one its start planned): its choice follows.
    public func move(chat: String, to key: String, machine: String) {
        guard let id = chosen.removeValue(forKey: ChatKey(machine: machine, chat: chat)) else { return }
        chosen[ChatKey(machine: machine, chat: key)] = id
    }

    /// The connection chosen for `chat` on `machine`, if any.
    public func connection(chat: String, machine: String) -> String? {
        chosen[ChatKey(machine: machine, chat: chat)]?.connection
    }

    /// Cloud first use's rule, set by the app (``CloudSetup/choose(harness:model:account:)``): the connection a Cloud
    /// chat that no Cloud start chose for launches on (`cmux chat --on vm`, `cmux cloud start-session`, a new chat
    /// opened in a machine's workspace). Nil: such a chat starts on the machine's own route.
    public var setup: CloudSetup?

    /// Opens the recovery form for the machine where this chat's connection failed.
    public func openModelConnectionSettings(machine: String, harness: String?) {
        let harness = harness ?? "codex"
        setup?.connect(family: CloudSetup.family(of: harness) ?? harness, machine: machine)
    }

    /// The credential the chat's start sends, read now. A chosen connection that cannot be read throws:
    /// the start says so instead of using another route. With no choice, the connection Cloud first use
    /// picks for `harness` (``setup``); nil when none serves it or it cannot be read (the machine's own route).
    public func launchCredential(chat: String, machine: String, harness: String? = nil, model: String? = nil) async throws -> CloudAgentCredential? {
        if let selection = chosen[ChatKey(machine: machine, chat: chat)],
           selection.harness == nil || selection.harness == harness {
            guard let connection = selection.connection else { return nil }
            return try await credential(forConnection: connection, model: model, harness: harness)
        }
        guard let picked = await setup?.choose(harness: harness, model: model, account: nil).connectionID else { return nil }
        let connection = await setup?.launchConnection(picked)
        if connection?.endpointCredentials == true || connection?.kind == CloudAgentCredential.chatGPTPlan {
            return try await credential(forConnection: picked, model: model, harness: harness)
        }
        return try? await credential(forConnection: picked, model: model, harness: harness)
    }

    /// Keeps the chat's delivered credential current after its start or reattach.
    @discardableResult
    public func started(chat: String, machine: String, on credential: CloudAgentCredential,
                        onReauth: @escaping @MainActor () -> Void = {},
                        replace: CloudAgentCredentialRefresher.Replace? = nil,
                        push: @escaping CloudAgentCredentialRefresher.Push) -> UUID? {
        let key = ChatKey(machine: machine, chat: chat)
        chosen[key] = nil
        if let previous = tracked.removeValue(forKey: key) { refresher.untrack(previous) }
        if !credential.refreshes && ["copilot-plan", "api-key", "endpoint"].contains(credential.kind) {
            keyDeliveries[key] = KeyDelivery(connection: credential.connectionID, harness: credential.harness ?? credential.family,
                                           model: credential.model, originalKind: credential.kind,
                                           replace: replace ?? { credential in await push(credential?.env ?? [:]) })
            credentialConnectionsChanged()
            return nil
        }
        keyDeliveries[key] = nil
        let id = refresher.track(credential, onReauth: onReauth, replace: replace, push: push)
        tracked[key] = id
        return id
    }
}
