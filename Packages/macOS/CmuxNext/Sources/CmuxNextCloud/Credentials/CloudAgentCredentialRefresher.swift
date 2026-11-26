public import CmuxNextDaemon
import CmuxNextWakeups
public import Foundation

/// Keeps each live ChatGPT plan agent on a Cloud machine on a fresh access token while this app
/// runs (model-connections.md "Revision 2": the Mac holds the refresh token). About ``lead`` before
/// the token an agent runs on expires, it reads the connection's credential again (this Mac's
/// acpmux refreshes it) and pushes the new token to every machine session with a live agent on that
/// connection (`agent-session-credentials` -> the machine acpmux's `agent/credentials.update`, which
/// restarts that Codex app-server on it and resumes its thread). One read per connection serves
/// all of its agents. A read or push that fails is tried again after ``retry``; an agent whose chat
/// is gone is dropped. Other kinds (a Claude token, an API key) do not expire and are not refreshed.
///
/// Every agent, of any kind, is also held by its machine so a new link to that machine (a VM that
/// paused and resumed, a daemon an update or a crash restarted) gets its chats' current credentials
/// again (``resend(machine:)``, cmux#57418): the machine's acpmux keeps a launch credential only in
/// memory, so one restarted while the chat's agent slept lost it, and the chat's next turn ran with no
/// sign-in ("Not logged in · Please run /login"). A push of the credential the session already holds
/// restarts nothing there (`agent/credentials.update` answers `restart: none`).
///
/// Each connection's deadline is a ``DemandTimer`` on the injected clock; the wall-clock expiry is
/// read through `now`.
@MainActor
public final class CloudAgentCredentialRefresher {
    /// What one push to one machine session did.
    public enum PushOutcome: Sendable, Equatable {
        case delivered
        /// A failure that may pass (a link down): tried again after ``retry``.
        case failed
        /// The chat is gone from that machine: no more pushes for it.
        case gone
    }

    /// Sends one agent's new credential env to its machine session.
    public typealias Push = @Sendable (_ env: [String: String]) async -> PushOutcome
    /// Reads a connection's credential now.
    public typealias Read = @MainActor (_ connectionID: String) async throws -> CloudAgentCredential

    /// How long before an agent's token expires a fresh one is pushed.
    public static let lead: Duration = .seconds(600)
    /// How long after a failed read or push it is tried again.
    public static let retry: Duration = .seconds(60)
    /// How long past its token's expiry an agent no push reached is still tried (a Mac that slept,
    /// a machine that was down); then it is dropped, as its chat no longer runs on that token.
    public static let giveUp: Duration = .seconds(86_400)

    private struct Agent {
        let push: Push
        /// The expiry of the token its machine has now.
        var delivered: Date
        var machine: String?
    }

    /// An agent on a credential that does not expire, held only to send again on a new link.
    private struct Held {
        let connectionID: String
        let machine: String
        let push: Push
    }

    private let read: Read
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private var agents: [String: [UUID: Agent]] = [:]
    private var held: [UUID: Held] = [:]
    /// The last live handshake seen per machine (``linked(machine:handshake:)``).
    private var handshakes: [String: String] = [:]
    private var timers: [String: DemandTimer] = [:]
    /// Connections whose refresh runs now: a track then waits for its end to reschedule.
    private var refreshing: Set<String> = []

    public init(clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { Date() }, read: @escaping Read) {
        (self.clock, self.now, self.read) = (clock, now, read)
    }

    /// Tracks an agent that started on `credential` on `machine`. One that does not expire is only held
    /// for ``resend(machine:)``; with no machine as well, it is not tracked (nil).
    @discardableResult
    public func track(_ credential: CloudAgentCredential, machine: String? = nil, push: @escaping Push) -> UUID? {
        guard credential.refreshes, let expires = credential.expiresAt else {
            guard let machine else { return nil }
            let id = UUID()
            held[id] = Held(connectionID: credential.connectionID, machine: machine, push: push)
            return id
        }
        let id = UUID()
        agents[credential.connectionID, default: [:]][id] = Agent(push: push, delivered: expires, machine: machine)
        if !refreshing.contains(credential.connectionID) { schedule(credential.connectionID, after: nil) }
        return id
    }

    /// Stops refreshing agent `id` (its chat closed or moved).
    public func untrack(_ id: UUID) {
        held[id] = nil
        for (connection, group) in agents where group[id] != nil {
            agents[connection]?[id] = nil
            if agents[connection]?.isEmpty == true { stop(connection) }
        }
    }

    /// How many agents are tracked now.
    public var trackedCount: Int { agents.values.reduce(0) { $0 + $1.count } + held.count }

    /// Machine `machine`'s daemon answered a new handshake `handshake` (a reconnect, a resume, a restarted
    /// daemon; nil while none is live): whether its chats' credentials are due again (``resend(machine:)``).
    /// The first handshake seen counts too, as the app cannot know what the machine kept meanwhile.
    public func linked(machine: String, handshake: String?) -> Bool {
        guard let handshake, handshakes[machine] != handshake else { return false }
        handshakes[machine] = handshake
        return held.values.contains { $0.machine == machine }
            || agents.values.contains { $0.values.contains { $0.machine == machine } }
    }

    /// Sends every tracked chat on `machine` its connection's credential again, read now (cmux#57418:
    /// a resumed VM or a restarted daemon re-gets what its acpmux lost). One read per connection; a
    /// chat its machine no longer has is dropped; a read or push that fails waits for the next link.
    /// How many pushes were delivered.
    @discardableResult
    public func resend(machine: String) async -> Int {
        var targets: [String: [(id: UUID, push: Push)]] = [:]
        for (id, agent) in held where agent.machine == machine { targets[agent.connectionID, default: []].append((id, agent.push)) }
        for (connection, group) in agents {
            for (id, agent) in group where agent.machine == machine { targets[connection, default: []].append((id, agent.push)) }
        }
        var delivered = 0
        for (connection, chats) in targets.sorted(by: { $0.key < $1.key }) {
            guard let fresh = try? await read(connection) else { continue }
            for chat in chats {
                switch await chat.push(fresh.env) {
                case .delivered:
                    delivered += 1
                    if let expires = fresh.expiresAt, let had = agents[connection]?[chat.id]?.delivered, expires > had {
                        agents[connection]?[chat.id]?.delivered = expires
                    }
                case .failed: break
                case .gone: untrack(chat.id)
                }
            }
        }
        return delivered
    }

    private func stop(_ connection: String) {
        agents[connection] = nil
        timers.removeValue(forKey: connection)?.cancel()
    }

    /// The next refresh of `connection`: when its soonest agent's token is ``lead`` from expiry, or
    /// `after` from now when that is later (a retry).
    private func schedule(_ connection: String, after floor: Duration?) {
        guard let group = agents[connection], let soonest = group.values.map(\.delivered).min() else {
            return stop(connection)
        }
        let due = soonest.timeIntervalSince(now()) - Double(Self.lead.components.seconds)
        let wait = max(.seconds(max(due, 0)), floor ?? .zero)
        let timer = timers[connection] ?? DemandTimer(owner: "cloud.agentCredentials.refresh", clock: clock)
        timers[connection] = timer
        timer.schedule(after: wait) { @MainActor [weak self] in await self?.refresh(connection) }
    }

    /// One refresh pass of `connection` (its timer's; internal for tests).
    func refresh(_ connection: String) async {
        refreshing.insert(connection)
        defer { refreshing.remove(connection) }
        let stale = now().addingTimeInterval(-Double(Self.giveUp.components.seconds))
        agents[connection] = agents[connection]?.filter { $0.value.delivered > stale }
        let cutoff = now().addingTimeInterval(Double(Self.lead.components.seconds))
        let due = (agents[connection] ?? [:]).filter { $0.value.delivered <= cutoff }
        if agents[connection]?.isEmpty ?? true { return stop(connection) }
        guard !due.isEmpty else { return schedule(connection, after: nil) }
        let fresh: CloudAgentCredential
        do { fresh = try await read(connection) } catch { return schedule(connection, after: Self.retry) }
        var retry = false
        for (id, agent) in due {
            guard let expires = fresh.expiresAt, expires > agent.delivered else {
                // This Mac's acpmux gave no newer token yet.
                retry = true
                continue
            }
            switch await agent.push(fresh.env) {
            case .delivered: agents[connection]?[id]?.delivered = expires
            case .failed: retry = true
            case .gone: agents[connection]?[id] = nil
            }
        }
        if agents[connection]?.isEmpty ?? true { return stop(connection) }
        schedule(connection, after: retry ? Self.retry : nil)
    }
}

extension CloudAgentCredentialRefresher {
    /// The push to the chat on tab `surface` of a Cloud machine's daemon: `agent-session-credentials`
    /// over the owner answer of its link (``AgentSessionAttachClient/updateCredentials(_:ownerLink:)``).
    /// A tab its machine no longer has (closed, or a daemon that takes no credential) is gone.
    public static func machinePush(surface: UInt64, ownerLink: AgentSessionAttachClient.OwnerLink?,
                                   reconnect: AgentSessionAttachClient.Reconnect?,
                                   endpoint: @escaping AgentSessionAttachClient.EndpointProvider) -> Push {
        { env in
            let client = AgentSessionAttachClient(surface: surface, reconnect: reconnect, endpoint: endpoint)
            let outcome: PushOutcome
            do {
                _ = try await client.updateCredentials(env, ownerLink: ownerLink)
                outcome = .delivered
            } catch let error as AgentSessionAttachError
                        where error.code == "agent_session.unknown_tab" || error.code == AgentSessionAttachClient.startUnsupported {
                outcome = .gone
            } catch {
                outcome = .failed
            }
            await client.close()
            return outcome
        }
    }
}
