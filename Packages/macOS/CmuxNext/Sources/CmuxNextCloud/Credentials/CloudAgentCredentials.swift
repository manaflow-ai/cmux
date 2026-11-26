public import CmuxNextDaemon
public import Foundation
import CryptoKit
import CmuxNextWakeups

/// One model connection's credential as this Mac's acpmux gives it for a Cloud chat
/// (`_acpmux/connections/credential {id}` -> `{family, kind, env, expires_at}`,
/// cmux-tui/docs/model-connections.md "Revision 2"): the variables the machine's agent launches
/// with, straight to the provider. Its descriptions and mirror name the variables, never a value.
public struct CloudAgentCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The kind whose access token expires and is refreshed while the app runs.
    public static let chatGPTPlan = "chatgpt-plan"

    public let connectionID: String
    let instance: String?
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
                harness: String? = nil, model: String? = nil, endpoint: AgentSessionAttachClient.LaunchEndpoint? = nil, instance: String? = nil) {
        (self.connectionID, self.family, self.kind, self.env, self.expiresAt) = (connectionID, family, kind, env, expiresAt)
        (self.harness, self.model, self.endpoint) = (harness, model, endpoint)
        self.instance = instance
    }

    /// The reply of `_acpmux/connections/credential` for `connectionID`; nil for any other shape.
    public init?(connectionID: String, reply: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let family = object["family"] as? String, let kind = object["kind"] as? String,
              let env = object["env"] as? [String: String], !env.isEmpty else { return nil }
        let instance = object["credential_instance"] as? String
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
                      harness: harness, model: model, endpoint: endpoint, instance: instance)
        } else {
            guard kind != "endpoint" else { return nil }
            self.init(connectionID: connectionID, family: family, kind: kind, env: env, expiresAt: expires, instance: instance)
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
/// Cloud chat starts on (the Cloud start picks it, ``use(choice:chat:machine:harness:claudeAuth:)``), and the
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
    private let machineIdentity: String?
    public var readForModel: (@MainActor (String, String) async throws -> Data)?
    /// The connection each new Cloud chat starts on, by machine and chat tab key.
    private var chosen: [ChatKey: Selection] = [:]
    private var tracked: [ChatKey: UUID] = [:]

    private struct Selection {
        let connection: CloudSetup.Choice?
        let harness: String?
        let claudeAuth: AgentSessionAttachClient.ClaudeAuth?
    }

    private struct ChatKey: Hashable { let machine: String, chat: String }

    private struct KeyDelivery: Sendable {
        var id = UUID()
        let binding: String
        let sessionID: String?
        let harness: String
        let model: String?
        let replace: CloudAgentCredentialRefresher.Replace
        let onDelivered: @MainActor () -> Void
        let onRefusal: @MainActor (Failure) -> Void
        // Reconciliation and scheduled refresh share this write queue.
        var write: Task<CloudAgentCredentialRefresher.PushOutcome, Never>?
        var withdrawalPending = false
    }

    package struct ConnectionState: Sendable {
        package let connections: [CloudSetup.Connection]
        fileprivate let disconnected: [String: [String]]

        package init(connections: [CloudSetup.Connection], disconnected: [String: [String]] = [:]) {
            self.connections = connections
            self.disconnected = disconnected
        }
    }

    /// Reads saved connections and explicit disconnects. Nil means the list is unavailable.
    package var readCredentialConnections: (@MainActor () async -> ConnectionState?)?
    /// Reconciles withdrawn bindings on connected guests, including chats without a pane.
    package var withdrawGuestBindings: (@MainActor ([String]) async -> Bool)?
    private var guestWithdrawalPending = false

    /// Subscribes to local connection changes while guest reconciliation is active.
    public var watchCredentialConnections: (@MainActor () async -> AsyncStream<Void>?)?
    private var keyWatch: Task<Void, Never>?
    private var keyDeliveries: [ChatKey: KeyDelivery] = [:]
    private(set) var keySync: Task<Void, Never>?
    private var keyChangesPending = false
    private let withdrawalRetry: DemandTimer

    /// Reconcile an owner's bound launches after a connection change or a guest reconnect.
    public func credentialConnectionsChanged() {
        guard withdrawGuestBindings != nil || !keyDeliveries.isEmpty else { return }
        startKeyWatch()
        queueKeySync()
    }

    private func startKeyWatch() {
        guard keyWatch == nil, let watchCredentialConnections else { return }
        // task-owner: keyWatch, until acpmux closes its watch or no bound chat remains.
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
        keySync = Task { [weak self] in await self?.syncKeys() }
    }

    private func syncKeys() async {
        defer {
            keySync = nil
            if keyDeliveries.isEmpty, withdrawGuestBindings == nil { keyWatch?.cancel() }
            if guestWithdrawalPending || keyDeliveries.values.contains(where: \.withdrawalPending) {
                withdrawalRetry.scheduleIfIdle(after: CloudAgentCredentialRefresher.retry) { @MainActor [weak self] in
                    self?.queueKeySync()
                }
            } else {
                withdrawalRetry.cancel()
            }
        }
        while keyChangesPending {
            keyChangesPending = false
            guard let state = await readCredentialConnections?() else { continue }
            for (chat, delivery) in keyDeliveries {
                await reconcile(chat, delivery: delivery, state: state)
            }
            if let withdrawGuestBindings, !keyChangesPending {
                let bindings = withdrawnBindings(in: state)
                if bindings.isEmpty {
                    guestWithdrawalPending = false
                } else {
                    guestWithdrawalPending = await !withdrawGuestBindings(bindings)
                }
            }
        }
    }

    private func withdrawnBindings(in state: ConnectionState) -> [String] {
        var withdrawn = Set<String>(state.connections.compactMap { connection in
            guard connection.canServeCloud, !connection.servesCloud else { return nil }
            return binding(connection: connection.id, instance: connection.credentialInstance)
        })
        for (id, instances) in state.disconnected {
            withdrawn.formUnion(instances.compactMap { binding(connection: id, instance: $0) })
        }
        return withdrawn.sorted()
    }

    private func reconcile(_ chat: ChatKey, delivery: KeyDelivery, state: ConnectionState) async {
        guard keyDeliveries[chat]?.id == delivery.id, let separator = delivery.binding.firstIndex(of: ":") else { return }
        let id = String(delivery.binding[..<separator])
        let connection = state.connections.first { binding(connection: $0.id, instance: $0.credentialInstance) == delivery.binding }
        let disconnected = state.disconnected[id]?.contains { binding(connection: id, instance: $0) == delivery.binding } == true
        if disconnected || connection.map({ $0.canServeCloud && !$0.servesCloud }) == true {
            stopRefresh(chat)
            let outcome = await send(nil, to: chat, delivery: delivery)
            guard keyDeliveries[chat]?.id == delivery.id else { return }
            keyDeliveries[chat]?.withdrawalPending = outcome == .failed
            if outcome == .delivered && disconnected { keyDeliveries[chat] = nil }
            // Keep an opted-out connection tracked so the same open chat resumes on re-enable.
            return
        }
        guard let connection, connection.servesCloud else { return }
        keyDeliveries[chat]?.withdrawalPending = false
        guard connection.enabled, connection.signedIn else { return }
        do {
            guard let credential = try await boundCredential(delivery.binding, model: delivery.model, harness: delivery.harness) else { return }
            guard await send(credential, to: chat, delivery: delivery) == .delivered,
                  keyDeliveries[chat]?.id == delivery.id else { return }
            trackRefresh(credential, chat: chat, delivery: delivery)
            delivery.onDelivered()
        } catch let failure as Failure {
            if keyDeliveries[chat]?.id == delivery.id { delivery.onRefusal(failure) }
        } catch {}
    }

    private func send(_ credential: CloudAgentCredential?, to chat: ChatKey, delivery: KeyDelivery) async
        -> CloudAgentCredentialRefresher.PushOutcome {
        guard let current = keyDeliveries[chat], current.id == delivery.id else { return .gone }
        // task-owner: the delivery retains its most recent write so the next write follows it.
        let write = Task { [weak self] in
            _ = await current.write?.value
            guard let next = self?.keyDeliveries[chat], next.id == delivery.id else {
                return CloudAgentCredentialRefresher.PushOutcome.gone
            }
            return await next.replace(credential)
        }
        keyDeliveries[chat]?.write = write
        let result = await write.value
        if result == .gone, keyDeliveries[chat]?.id == delivery.id {
            keyDeliveries[chat] = nil
            stopRefresh(chat)
            if keyDeliveries.isEmpty, withdrawGuestBindings == nil { keyWatch?.cancel() }
        }
        return result
    }

    private func stopRefresh(_ chat: ChatKey) {
        if let previous = tracked.removeValue(forKey: chat) { refresher.untrack(previous) }
    }

    @discardableResult
    private func trackRefresh(_ credential: CloudAgentCredential, chat: ChatKey, delivery: KeyDelivery) -> UUID? {
        stopRefresh(chat)
        let id = refresher.track(credential, onReauth: {
            delivery.onRefusal(.refused(reason: "chatgpt.reauth_required"))
        }, replace: { [weak self] credential in
            guard let self, let credential else { return .gone }
            return await self.refresh(credential, chat: chat, delivery: delivery)
        }, push: { _ in .gone })
        tracked[chat] = id
        return id
    }

    private func refresh(_ credential: CloudAgentCredential, chat: ChatKey, delivery: KeyDelivery) async
        -> CloudAgentCredentialRefresher.PushOutcome {
        guard tracked[chat] != nil else { return .gone }
        return await send(credential, to: chat, delivery: delivery)
    }

    /// Reattach through the same reconciliation as Settings, including a refused withdrawal.
    package func restoreBinding(_ binding: String, chat: String, machine: String, sessionID: String, harness: String, model: String?,
                                replace: @escaping CloudAgentCredentialRefresher.Replace,
                                onDelivered: @escaping @MainActor () -> Void,
                                onRefusal: @escaping @MainActor (Failure) -> Void) async {
        let key = ChatKey(machine: machine, chat: chat)
        let previous = keyDeliveries[key]
        let sameBinding = previous?.binding == binding && previous?.sessionID == sessionID
        if !sameBinding { stopRefresh(key) }
        keyDeliveries[key] = KeyDelivery(id: (sameBinding ? previous?.id : nil) ?? UUID(), binding: binding,
                                         sessionID: sessionID, harness: harness, model: model, replace: replace,
                                         onDelivered: onDelivered, onRefusal: onRefusal, write: previous?.write,
                                         withdrawalPending: sameBinding && previous?.withdrawalPending == true)
        credentialConnectionsChanged()
        await keySync?.value
    }

    public private(set) lazy var refresher = CloudAgentCredentialRefresher { [weak self] id in
        guard let self else { throw Failure.unavailable(connection: id) }
        return try await self.credential(forConnection: id)
    }

    public init(machineIdentity: String? = nil, clock: any Clock<Duration> = ContinuousClock(), read: Read? = nil) {
        self.machineIdentity = machineIdentity
        self.withdrawalRetry = DemandTimer(owner: "cloud.agentCredentials.withdrawalRetry", clock: clock)
        self.read = read
    }

    /// The guest stores the route id with a digest scoped to this Mac and this saved connection.
    package func credentialBinding(_ credential: CloudAgentCredential) -> String? {
        binding(connection: credential.connectionID, instance: credential.instance)
    }

    private func binding(connection: String, instance: String?) -> String? {
        guard let machineIdentity, let instance, let uuid = UUID(uuidString: instance) else { return nil }
        let data = Data("cmux.cloud.credential\n\(machineIdentity)\n\(uuid.uuidString)".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(connection):\(digest)"
    }

    package func boundCredential(_ expected: String, model: String?, harness: String?) async throws -> CloudAgentCredential? {
        guard let separator = expected.firstIndex(of: ":") else { return nil }
        let id = String(expected[..<separator])
        let fresh = try await credential(forConnection: id, model: model, harness: harness)
        return credentialBinding(fresh) == expected ? fresh : nil
    }

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

    /// Records the connection or explicit Claude route for this chat's pending launch.
    public func use(choice: CloudSetup.Choice = .fallback, chat: String, machine: String, harness: String? = nil, claudeAuth: AgentSessionAttachClient.ClaudeAuth? = nil) {
        let key = ChatKey(machine: machine, chat: chat)
        if case .connection = choice {
            chosen[key] = Selection(connection: choice, harness: harness, claudeAuth: nil)
        } else {
            chosen[key] = claudeAuth.map { Selection(connection: nil, harness: harness, claudeAuth: $0) }
        }
    }

    public func stopDeliveringCredential(chat: String, machine: String, harness: String) {
        let key = ChatKey(machine: machine, chat: chat)
        chosen[key] = Selection(connection: nil, harness: harness, claudeAuth: nil)
        keyDeliveries[key] = nil
        stopRefresh(key)
    }

    /// The chat's tab got the key `key` on `machine` (not the one its start planned): its choice follows.
    public func move(chat: String, to key: String, machine: String) {
        guard let id = chosen.removeValue(forKey: ChatKey(machine: machine, chat: chat)) else { return }
        chosen[ChatKey(machine: machine, chat: key)] = id
    }

    /// The guest authentication source the Cloud start selected for this harness.
    public func claudeAuth(chat: String, machine: String, harness: String?) -> AgentSessionAttachClient.ClaudeAuth? {
        guard CloudSetup.family(of: harness) == "claude",
              let selection = chosen[ChatKey(machine: machine, chat: chat)],
              selection.harness == nil || selection.harness == harness else { return nil }
        return selection.claudeAuth
    }

    /// The connection chosen for `chat` on `machine`, if any.
    package func connectionChoice(chat: String, machine: String) -> CloudSetup.Choice? {
        chosen[ChatKey(machine: machine, chat: chat)]?.connection
    }

    /// Cloud first use's rule, set by the app (``CloudSetup/choose(harness:model:account:)``): the connection a Cloud
    /// chat that no Cloud start chose for launches on (`cmux chat --on vm`, `cmux cloud start-session`, a new chat
    /// opened in a machine's workspace). Nil: such a chat starts on the machine's own route.
    public var setup: CloudSetup?

    /// Opens the recovery form for the machine where this chat's connection failed.
    public func openModelConnectionSettings(machine: String, harness: String?, session: String?) {
        let harness = harness ?? "codex"
        let family = CloudSetup.family(of: harness) ?? harness
        setup?.connect(family: family, machine: machine, recoverySession: family == "claude" ? session : nil)
    }

    /// The credential the chat's start sends, read now. A chosen connection that cannot be read throws:
    /// the start says so instead of using another route. With no choice, the connection Cloud first use
    /// picks for `harness` (``setup``). A selected Gemini or Grok connection must still match its saved instance.
    public func launchCredential(chat: String, machine: String, harness: String? = nil, model: String? = nil) async throws -> CloudAgentCredential? {
        if let selection = chosen[ChatKey(machine: machine, chat: chat)],
           selection.harness == nil || selection.harness == harness,
           selection.claudeAuth == nil || CloudSetup.family(of: harness) == "claude" {
            guard let connection = selection.connection else { return nil }
            return try await launchCredential(for: connection, harness: harness, model: model)
        }
        guard let choice = await setup?.choose(harness: harness, model: model, account: nil),
              let picked = choice.connectionID else { return nil }
        if choice.requiresCredentialInstance {
            return try await launchCredential(for: choice, harness: harness, model: model)
        }
        let connection = await setup?.launchConnection(picked)
        if connection?.endpointCredentials == true || connection?.kind == CloudAgentCredential.chatGPTPlan {
            return try await credential(forConnection: picked, model: model, harness: harness)
        }
        return try? await credential(forConnection: picked, model: model, harness: harness)
    }

    /// Reads the launch credential for a choice already made, including when prewarming the agent.
    package func launchCredential(for choice: CloudSetup.Choice, harness: String?, model: String?) async throws -> CloudAgentCredential? {
        guard case .connection(let id, _, let instance) = choice else { return nil }
        let credential = try await credential(forConnection: id, model: model, harness: harness)
        if choice.requiresCredentialInstance {
            guard let expected = instance.flatMap(UUID.init(uuidString:)),
                  credential.instance.flatMap(UUID.init(uuidString:)) == expected else {
                throw Failure.unavailable(connection: id)
            }
        }
        return credential
    }

    /// The login a move to `machine` carries (`link agent move --login-stdin`), read now, so the chat resumes there signed in:
    /// only when the Cloud API said the machine is the owner's (`vmKind` `owner`). As ``launchCredential(chat:machine:harness:model:)``,
    /// a chosen connection that cannot be read throws, and the move stays where it is.
    public func moveCredential(vmKind: String, chat: String, machine: String, harness: String?) async throws -> CloudAgentCredential? {
        guard vmKind == "owner",
              let credential = try await launchCredential(chat: chat, machine: machine, harness: harness) else { return nil }
        guard credential.endpoint == nil, credential.env.count == 1, let name = credential.env.keys.first else {
            throw Failure.refused(reason: "connections.move_unsupported")
        }
        // The move carries the connection's binding with a setup token or an API key, so a later opt-out
        // or Disconnect reaches the moved chat. A connection with no binding cannot be withdrawn: refuse.
        switch name {
        case "CMUX_CHATGPT_ACCESS_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN":
            return credential
        case "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN":
            guard credentialBinding(credential) != nil else { throw Failure.unavailable(connection: credential.connectionID) }
            return credential
        default:
            throw Failure.refused(reason: "connections.move_unsupported")
        }
    }

    /// A move that carried `credential` landed on the machine's tab `surface`: as ``started(chat:machine:sessionID:on:onReauth:replace:push:)``, its ChatGPT
    /// plan token kept fresh there as after a Cloud start. No credential: nothing.
    public func moved(chat: String, machine: String, on credential: CloudAgentCredential?, surface: UInt64,
                      ownerLink: AgentSessionAttachClient.OwnerLink?, endpoint: @escaping AgentSessionAttachClient.EndpointProvider) {
        guard let credential else { return }
        let key = ChatKey(machine: machine, chat: chat)
        chosen[key] = nil
        stopRefresh(key)
        let push = CloudAgentCredentialRefresher.machinePush(surface: surface, sessionID: chat, ownerLink: ownerLink, reconnect: nil, endpoint: endpoint)
        tracked[key] = refresher.track(credential, push: push)
    }

    /// The chat started on `credential`: its choice is spent, and a ChatGPT plan token is kept fresh
    /// on that machine through `push` (``CloudAgentCredentialRefresher/track(_:push:)``).
    @discardableResult
    public func started(chat: String, machine: String, sessionID: String? = nil, on credential: CloudAgentCredential,
                        onReauth: @escaping @MainActor () -> Void = {},
                        replace: CloudAgentCredentialRefresher.Replace? = nil,
                        push: @escaping CloudAgentCredentialRefresher.Push) -> UUID? {
        let key = ChatKey(machine: machine, chat: chat)
        chosen[key] = nil
        stopRefresh(key)
        guard let binding = credentialBinding(credential) else {
            keyDeliveries[key] = nil
            // A pre-instance Mac daemon still returns valid ChatGPT refresh tokens.
            let id = refresher.track(credential, onReauth: onReauth, replace: replace, push: push)
            tracked[key] = id
            return id
        }
        let delivery = KeyDelivery(binding: binding, sessionID: sessionID, harness: credential.harness ?? credential.family, model: credential.model,
                                   replace: replace ?? { credential in await push(credential?.env ?? [:]) },
                                   onDelivered: {}, onRefusal: { if $0.requiresSignIn { onReauth() } },
                                   write: keyDeliveries[key]?.write)
        keyDeliveries[key] = delivery
        credentialConnectionsChanged()
        return trackRefresh(credential, chat: key, delivery: delivery)
    }
}
