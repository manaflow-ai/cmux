import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Invite People (plan teammate-invites, design chat-multiplayer.md 2): a cmux account joins a chat
/// after signing in, as a viewer or a talker whose every message waits for the owner. The palette's
/// Invite People to Chat…, `cmux share invite` and its MCP tool run `agent.share.invite`; `cmux share
/// uninvite` and its tool run `agent.share.uninvite`. The daemon keeps the invitees on a share
/// (`agent-session-share-invite|uninvite`); this only finds the chat's invite share, makes one
/// first when the chat has none, and asks the owner when a run they did not start invites someone.
extension AgentShareActions {
    /// A share an invite makes lasts the longest a share may (the daemon's 7 days), unless --ttl says.
    static let inviteTTL: UInt64 = AgentShareArguments.maximumTTL

    func bindInvites(into registry: ActionRegistry) {
        let host = host
        registry.bindEffect(Self.invite, effect: { invocation in
            let chat: AgentShareChat
            switch Self.chat(invocation, host: host) {
            case .success(let found): chat = found
            case .failure(let refusal): return Self.refused(refusal, registry)
            }
            // The owner's install token goes only to this Mac's daemon (a new share needs it).
            guard chat.isLocal else { return .refused(AgentShareStrings.notThisMac) }
            guard let account = Self.argument(invocation, "account") else { return .refused(AgentShareStrings.needsAccount) }
            guard let role = AgentShareInvites.role(invocation["role"]?.stringValue) else { return .refused(AgentShareStrings.badRole) }
            let ttl: UInt64?
            do { ttl = try AgentShareArguments.ttl(invocation["ttl"]?.stringValue) } catch { return .refused(AgentShareStrings.badTTL) }
            let person = Self.ownerStarted(invocation)
            let ask = AgentShareConsentAsk(chat: chat.title, ttlSecs: nil, uses: nil, invite: .init(account: account, role: role))
            return Self.answer(registry) {
                // An invite opens the chat's whole transcript to an account: only the owner's yes
                // makes one (#30263), asked before any share or token exists.
                if !person, !(await host.shareAskOwner(ask)) { throw AgentShareDeclined(invite: true) }
                let connection = try Self.connected(chat.connection)
                let listed = try await connection.request(AgentSessionShareListRequest(surface: chat.surface))
                let existing = AgentShareInvites.inviteShare(of: chat.session, in: listed.shares)
                let shareID: String
                if let existing {
                    shareID = existing
                } else {
                    shareID = try await Self.create(chat, ttl: ttl ?? Self.inviteTTL, uses: nil, host: host).shareId
                }
                let reply: JSONValue
                do {
                    reply = try await connection.request(AgentSessionShareInviteRequest(shareId: shareID, account: account, role: role))
                } catch {
                    // A share made only for this invite, which the daemon then refused (not an email or
                    // @handle, say), would sit open with nobody on it: end it.
                    if existing == nil { _ = try? await connection.request(AgentSessionShareRevokeRequest(shareId: shareID)) }
                    // The daemon's one refusal of a well-formed invite's params is the account's shape.
                    if case DaemonError.command(_, _, "share.bad_request"?, _, _) = error { throw AgentShareBadAccount() }
                    throw error
                }
                var result = AgentShareResults.ended(reply)
                result["created_share"] = .bool(existing == nil)
                if person { host.shareNotice(AgentShareStrings.invited(AgentShareInvites.text(result["account"]) ?? account, role: role)) }
                return result
            }
        })
        registry.bindEffect(Self.uninvite, effect: { invocation in
            guard let account = Self.argument(invocation, "account") else { return .refused(AgentShareStrings.needsAccount) }
            let shareID = Self.argument(invocation, "shareId")
            var chat: AgentShareChat?
            if shareID == nil {
                switch Self.chat(invocation, host: host) {
                case .success(let found) where !found.isLocal: return .refused(AgentShareStrings.notThisMac)
                case .success(let found): chat = found
                case .failure(let refusal): return Self.refused(refusal, registry)
                }
            }
            let connection = chat?.connection ?? host.shareLocalConnection
            return Self.answer(registry) {
                let connection = try Self.connected(connection)
                var shares = [String]()
                if let shareID {
                    shares = [shareID]
                } else if let chat {
                    let listed = try await connection.request(AgentSessionShareListRequest(surface: chat.surface))
                    shares = AgentShareInvites.sharesInviting(account, of: chat.session, in: listed.shares)
                }
                guard !shares.isEmpty else { throw AgentShareNotInvited(account: account) }
                var removed = account
                for share in shares {
                    let reply = try await connection.request(AgentSessionShareUninviteRequest(shareId: share, account: account))
                    removed = AgentShareInvites.text(AgentShareResults.ended(reply)["account"]) ?? removed
                }
                return ["account": .string(removed), "state": .string("removed"), "share_ids": .array(shares.map(ActionResultValue.string))]
            }
        })
    }
}

/// The choices an invite run makes from the chat's shares.
enum AgentShareInvites {
    /// `--role`: `talk` when absent, `view` or `talk` (any case); nil for anything else.
    static func role(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return "talk" }
        return ["view", "talk"].contains(text) ? text : nil
    }

    static func text(_ value: ActionResultValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    /// An account as the daemon compares it (trimmed, lowercased).
    static func normal(_ account: String) -> String { account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The share new invites to `session`'s chat go on: the newest live share that already has
    /// invitees. A guest link without any is left alone (its 24 hours and single use are the link's),
    /// so nil makes a new share for invites.
    static func inviteShare(of session: String, in shares: [AgentSessionShare]) -> String? {
        shares.filter { $0.session == session && $0.isLive && !$0.invitees.isEmpty }.max { $0.createdAt < $1.createdAt }?.shareId
    }

    /// Every share of `session`'s chat on which `account` is still invited.
    static func sharesInviting(_ account: String, of session: String, in shares: [AgentSessionShare]) -> [String] {
        let account = normal(account)
        return shares.filter { share in
            share.session == session && share.invitees.contains { $0.isInvited && $0.account == account }
        }.map(\.shareId)
    }
}

/// The daemon refused the invite's account: not an email address or an `@handle`.
struct AgentShareBadAccount: Error, Equatable {}

/// `share uninvite` named an account no share of the chat invites.
struct AgentShareNotInvited: Error, Equatable {
    var account: String
}
