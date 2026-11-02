public import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Share Chat with Guest (design chat-multiplayer.md 1 and 6, hq#4766): one link to one agent chat
/// that works once and expires in 24 hours by default. The palette, the chat tab's menu, `cmux share
/// chat` and its MCP tool run `agent.share`; `cmux share list|revoke|kick` and their tools run the
/// other three. The daemon owns the share (`agent-session-share-*` on its owner-only unix socket);
/// the app adds the owner's cmux install token, which the daemon spends on the hosted room's
/// provisioning and never stores.
@MainActor
public struct AgentShareActions {
    public static let share: ActionID = "agent.share"
    public static let list: ActionID = "agent.share.list"
    public static let revoke: ActionID = "agent.share.revoke"
    public static let kick: ActionID = "agent.share.kick"

    /// How long a create waits for the daemon: the room's 15 s provisioning budget and some margin.
    public static let createDeadline: Duration = .seconds(20)

    let host: any AgentShareHost

    public init(host: any AgentShareHost) { self.host = host }

    public func bind(into registry: ActionRegistry) {
        let host = host
        registry.bindEffect(Self.share, effect: { invocation in
            let chat: AgentShareChat
            switch Self.chat(invocation, host: host) {
            case .success(let found): chat = found
            case .failure(let refusal): return Self.refused(refusal, registry)
            }
            // The owner's install token goes only to this Mac's daemon: another machine's chat is refused
            // before a token is minted.
            guard chat.isLocal else { return .refused(AgentShareStrings.notThisMac) }
            let ttl: UInt64?
            do { ttl = try AgentShareArguments.ttl(invocation["ttl"]?.stringValue) } catch { return .refused(AgentShareStrings.badTTL) }
            if invocation["uses"] != nil, invocation["uses"]?.intValue == nil { return .refused(AgentShareStrings.badUses) }
            let uses = invocation["uses"]?.intValue.map { UInt32(clamping: $0) }
            let person = Self.ownerStarted(invocation)
            let ask = AgentShareConsentAsk(chat: chat.title, ttlSecs: ttl, uses: uses)
            return Self.answer(registry) {
                // A link exposes the chat's whole transcript: only the owner's yes makes one (#30263).
                // Asked before the owner's token is minted, so a declined run spends nothing.
                if !person, !(await host.shareAskOwner(ask)) { throw AgentShareDeclined() }
                let token = await host.shareOwnerToken()
                // The session pins the chat: the daemon refuses if the surface shows another one by now.
                let createID = UUID().uuidString
                let request = AgentSessionShareCreateRequest(surface: chat.surface, session: chat.session, createId: createID, ttlSecs: ttl,
                                                             uses: uses, ownerToken: token)
                // Create waits out the hosted room's provisioning (its request budget is 15 s,
                // agent_session_share_room.rs): its answer is the only copy of the link's secret.
                let connection = try Self.connected(chat.connection)
                let created: AgentSessionShareCreated
                do {
                    created = try await connection.request(request, timeout: Self.createDeadline)
                } catch DaemonError.timedOut(let what) {
                    // The daemon may still have made the link, but its secret was only in the answer
                    // that never came: no one can use it, so end it rather than leave it live.
                    await Self.revokeUnanswered(createID: createID, on: connection)
                    throw DaemonError.timedOut(what)
                }
                // A person's palette or menu run copies the link at once; a script gets it back.
                if person { Self.announce(created, host: host) }
                return AgentShareResults.created(created)
            }
        })
        registry.bindEffect(Self.list, effect: { invocation in
            var surface: UInt64?
            if invocation["surface"] != nil || invocation.target != nil {
                switch Self.chat(invocation, host: host) {
                // List reads this Mac's shares, so another machine's surface number would name a local chat.
                case .success(let chat) where !chat.isLocal: return .refused(AgentShareStrings.notThisMac)
                case .success(let chat): surface = chat.surface
                case .failure(let refusal): return Self.refused(refusal, registry)
                }
            }
            let connection = host.shareLocalConnection
            return Self.answer(registry) {
                AgentShareResults.list(try await Self.connected(connection).request(AgentSessionShareListRequest(surface: surface)))
            }
        })
        registry.bindEffect(Self.revoke, effect: { invocation in
            guard let shareID = Self.argument(invocation, "shareId") else { return .refused(AgentShareStrings.needsShareID) }
            let connection = host.shareLocalConnection
            return Self.answer(registry) {
                AgentShareResults.ended(try await Self.connected(connection).request(AgentSessionShareRevokeRequest(shareId: shareID)))
            }
        })
        registry.bindEffect(Self.kick, effect: { invocation in
            guard let shareID = Self.argument(invocation, "shareId") else { return .refused(AgentShareStrings.needsShareID) }
            guard let guestID = Self.argument(invocation, "guestId") else { return .refused(AgentShareStrings.needsGuestID) }
            let connection = host.shareLocalConnection
            return Self.answer(registry) {
                let request = AgentSessionShareKickRequest(shareId: shareID, guestId: guestID)
                return AgentShareResults.ended(try await Self.connected(connection).request(request))
            }
        })
        // Only a started agent chat's tab offers Share with Guest…; a terminal's or a new chat's leaves it out.
        ActionTargetVisibility.hide(Self.share, in: registry) { invocation in
            guard let target = invocation.target, target.kind == .tab else { return false }
            return host.shareTab(id: target.id).flatMap(AgentShareChat.session(of:)) == nil
        }
    }

    /// The chat a run names: `--surface N` (this Mac's surface), the tab it targets, the chat whose
    /// agent ran the CLI, else the focused tab. Only a started agent chat can be shared.
    static func chat(_ invocation: ActionInvocation, host: any AgentShareHost) -> Result<AgentShareChat, AgentShareRefusal> {
        let tab: TabModel?
        // A selector that is malformed, or two that could disagree, never falls back to another chat.
        if invocation["surface"] != nil, invocation["surface"]?.intValue == nil {
            return .failure(AgentShareRefusal(reason: AgentShareStrings.badSurface))
        }
        if invocation["surface"] != nil, invocation.target != nil {
            return .failure(AgentShareRefusal(reason: AgentShareStrings.surfaceAndTarget))
        }
        if let target = invocation.target, target.kind != .tab {
            return .failure(AgentShareRefusal(reason: AgentShareStrings.notAChat))
        }
        if let surface = invocation["surface"]?.intValue {
            guard surface > 0, let found = host.shareTab(surface: SurfaceID(rawValue: UInt64(surface))) else {
                return .failure(AgentShareRefusal(reason: AgentShareStrings.noSurface(surface), isNotFound: true))
            }
            tab = found
        } else if let target = invocation.target {
            guard let found = host.shareTab(id: target.id) else {
                return .failure(AgentShareRefusal(reason: AgentShareStrings.notAChat, isNotFound: true))
            }
            tab = found
        } else if let caller = invocation.callerAgentSession {
            // An agent's run names its own chat. When that chat is not found here, the run is
            // refused: falling back to the focused chat would share one the agent never named.
            guard let id = host.shareTabID(showing: caller), let found = host.shareTab(id: id) else {
                return .failure(AgentShareRefusal(reason: AgentShareStrings.notAChat, isNotFound: true))
            }
            tab = found
        } else {
            tab = host.shareFocusedTabID.flatMap(host.shareTab(id:))
        }
        guard let tab, let session = AgentShareChat.session(of: tab) else { return .failure(AgentShareRefusal(reason: AgentShareStrings.notAChat)) }
        return .success(AgentShareChat(surface: tab.surface.rawValue, session: session, connection: host.shareConnection(holding: tab),
                                       isLocal: host.shareIsOnThisMac(tab), title: tab.title))
    }

    /// Whether the owner started the run in this app (palette, menu, key): their gesture is their
    /// consent. Everything else asks first: the CLI, MCP, a script, a page, another client, a run that
    /// names a caller (an app, an agent chat, a terminal), and any control socket run, whose `user`
    /// origin is only the caller's claim (``ActionInvocation/isPersonsOwnRun``). A nested run is also
    /// judged by the run that encloses it (``ActionRunScope``).
    static func ownerStarted(_ invocation: ActionInvocation) -> Bool {
        invocation.isPersonsOwnRun && (ActionRunScope.current?.origin ?? .user) == .user
    }

    /// A target that names nothing answers `not_found` (``ActionRegistry/refuseNotFound(_:)``); any
    /// other refusal answers `unavailable`.
    private static func refused(_ refusal: AgentShareRefusal, _ registry: ActionRegistry) -> ActionEffect {
        guard refusal.isNotFound else { return .refused(refusal.reason) }
        registry.refuseNotFound(refusal.reason)
        return .done
    }

    private static func argument(_ invocation: ActionInvocation, _ name: String) -> String? {
        invocation[name]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Revokes the share this run's unanswered create made (`createID`), if the daemon made one.
    /// Only that share: another caller's create of the same chat is untouched. Best effort: a
    /// failure leaves it to expire.
    private static func revokeUnanswered(createID: String, on connection: DaemonConnection) async {
        guard let listed = try? await connection.request(AgentSessionShareListRequest()) else { return }
        for share in listed.shares where share.createId == createID && (share.state == "provisioning" || share.state == "active") {
            _ = try? await connection.request(AgentSessionShareRevokeRequest(shareId: share.shareId))
        }
    }

    private static func connected(_ connection: DaemonConnection?) throws -> DaemonConnection {
        guard let connection else { throw DaemonError.notConnected }
        return connection
    }

    /// The share's daemon work, answered to a waiting caller as `action.run` `result`; a person's
    /// run sees its failure as the registry's refusal notice.
    private static func answer(_ registry: ActionRegistry,
                               _ work: @escaping @MainActor () async throws -> [String: ActionResultValue]) -> ActionEffect {
        // task-owner: the action run (its `.waiting` work awaits it; a waiting caller gets its value)
        let task: ActionResultWork = Task { @MainActor in
            do { return .success(try await work()) } catch { return .failure(AgentShareStrings.failure(error)) }
        }
        registry.track(result: task)
        // action-wait-allow: the daemon's share record (and for create, the hosted room over the network) decides the answer
        return .waiting(.network) {
            guard case .failure(let failure) = await task.value else { return nil }
            return failure
        }
    }

    /// A person's run: the link goes on the pasteboard and a toast says so (the share sheet replaces this).
    private static func announce(_ created: AgentSessionShareCreated, host: any AgentShareHost) {
        let message: String
        if let url = created.url {
            host.shareCopy(url)
            message = AgentShareStrings.copied
        } else {
            message = AgentShareStrings.noRoom
        }
        host.shareNotice(message)
    }
}

/// The chat a share names: its surface on the daemon of `connection`.
struct AgentShareChat {
    let surface: UInt64
    /// The acpmux session the surface showed when the run named it.
    var session = ""
    let connection: DaemonConnection?
    /// Whether `connection` is this Mac's daemon, the only one shares are made and listed on.
    var isLocal = true
    /// The chat's tab title, named in the owner's consent sheet.
    var title = ""

    /// The acpmux session of a started agent chat; nil for every other tab.
    @MainActor static func session(of tab: TabModel) -> String? {
        tab.agentSession?.session.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The owner declined (or did not answer) the consent sheet of a run they did not start: no link.
struct AgentShareDeclined: Error, Equatable {}

struct AgentShareRefusal: Error, Equatable {
    var reason: String
    var isNotFound = false
}
