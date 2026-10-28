public import CmuxNextActions
import CmuxNextDaemon

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

    let host: any AgentShareHost

    public init(host: any AgentShareHost) { self.host = host }

    public func bind(into registry: ActionRegistry) {
        let host = host
        registry.bindEffect(Self.share, effect: { invocation in
            let chat: AgentShareChat
            switch Self.chat(invocation, host: host) {
            case .success(let found): chat = found
            case .failure(let refusal): return .refused(refusal.reason)
            }
            let ttl: UInt64?
            do { ttl = try AgentShareArguments.ttl(invocation["ttl"]?.stringValue) } catch { return .refused(AgentShareStrings.badTTL) }
            let uses = invocation["uses"]?.intValue.map { UInt32(clamping: $0) }
            let person = invocation.origin == .user
            return Self.answer(registry) {
                let token = await host.shareOwnerToken()
                let request = AgentSessionShareCreateRequest(surface: chat.surface, ttlSecs: ttl, uses: uses, ownerToken: token)
                let created = try await Self.connected(chat.connection).request(request)
                // A person's palette or menu run copies the link at once; a script gets it back.
                if person { Self.announce(created, host: host) }
                return AgentShareResults.created(created)
            }
        })
        registry.bindEffect(Self.list, effect: { invocation in
            var surface: UInt64?
            if invocation["surface"] != nil || invocation.target != nil {
                switch Self.chat(invocation, host: host) {
                case .success(let chat): surface = chat.surface
                case .failure(let refusal): return .refused(refusal.reason)
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
        if let surface = invocation["surface"]?.intValue {
            guard surface > 0, let found = host.shareTab(surface: SurfaceID(rawValue: UInt64(surface))) else {
                return .failure(AgentShareRefusal(reason: AgentShareStrings.noSurface(surface), isNotFound: true))
            }
            tab = found
        } else if let target = invocation.target, target.kind == .tab {
            guard let found = host.shareTab(id: target.id) else {
                return .failure(AgentShareRefusal(reason: AgentShareStrings.notAChat, isNotFound: true))
            }
            tab = found
        } else if invocation.target == nil, let caller = invocation.callerAgentSession, let id = host.shareTabID(showing: caller) {
            tab = host.shareTab(id: id)
        } else {
            tab = host.shareFocusedTabID.flatMap(host.shareTab(id:))
        }
        guard let tab, AgentShareChat.session(of: tab) != nil else { return .failure(AgentShareRefusal(reason: AgentShareStrings.notAChat)) }
        return .success(AgentShareChat(surface: tab.surface.rawValue, connection: host.shareConnection(holding: tab)))
    }

    private static func argument(_ invocation: ActionInvocation, _ name: String) -> String? {
        invocation[name]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
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
    let connection: DaemonConnection?

    /// The acpmux session of a started agent chat; nil for every other tab.
    @MainActor static func session(of tab: TabModel) -> String? {
        tab.agentSession?.session.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct AgentShareRefusal: Error, Equatable {
    var reason: String
    var isNotFound = false
}
