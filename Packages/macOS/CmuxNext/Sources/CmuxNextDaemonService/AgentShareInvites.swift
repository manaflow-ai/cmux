import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Invite People (plan teammate-invites, design chat-multiplayer.md 2): a cmux account joins a chat
/// after signing in, as a viewer or a talker whose every message waits for the owner. The palette's
/// Invite People to Chat…, the tab menu's Invite People… (both open the Invite People sheet),
/// `cmux share invite` and its MCP tool run `agent.share.invite`; `cmux share uninvite` and its tool
/// run `agent.share.uninvite`. The daemon keeps the invitees on a share
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
            guard let role = AgentShareInvites.role(invocation["role"]?.stringValue) else { return .refused(AgentShareStrings.badRole) }
            guard let account = Self.argument(invocation, "account") else {
                // The palette's Invite People to Chat… and the tab menu's Invite People… name nobody: the
                // owner's own run opens the sheet; an agent or script must name the account.
                guard Self.ownerStarted(invocation) else { return .refused(AgentShareStrings.needsAccount) }
                host.shareShowInvites(Self.inviteSheet(chat, role: role, host: host))
                return .done
            }
            let ttl: UInt64?
            do { ttl = try AgentShareArguments.ttl(invocation["ttl"]?.stringValue) } catch { return .refused(AgentShareStrings.badTTL) }
            let person = Self.ownerStarted(invocation)
            let ask = AgentShareConsentAsk(chat: chat.title, ttlSecs: nil, uses: nil, invite: .init(account: account, role: role))
            return Self.answer(registry) {
                // An invite opens the chat's whole transcript to an account: only the owner's yes
                // makes one (#30263), asked before any share or token exists.
                if !person, !(await host.shareAskOwner(ask)) { throw AgentShareDeclined(invite: true) }
                let result = try await Self.inviteWork(chat, account: account, role: role, ttl: ttl, host: host)
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
                try await Self.uninviteWork(account: account, shareID: shareID, chat: chat, connection: connection)
            }
        })
        // Only a started agent chat's tab offers Invite People…, as with Share with Guest….
        ActionTargetVisibility.hide(Self.invite, in: registry) { invocation in
            guard let target = invocation.target, target.kind == .tab else { return false }
            return host.shareTab(id: target.id).flatMap(AgentShareChat.session(of:)) == nil
        }
    }
}

extension AgentShareActions {
    /// An invite's work, for the op and the sheet alike: the account goes on the chat's invite share,
    /// made first when the chat has none. The caller has the owner's consent already.
    static func inviteWork(_ chat: AgentShareChat, account: String, role: String, ttl: UInt64?,
                           host: any AgentShareHost) async throws -> [String: ActionResultValue] {
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
        return result
    }

    /// An uninvite's work, for the op and the sheet: the account leaves `shareID`, or every share of
    /// `chat` that still invites it.
    static func uninviteWork(account: String, shareID: String?, chat: AgentShareChat?,
                             connection: DaemonConnection?) async throws -> [String: ActionResultValue] {
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

    /// The Invite People sheet's model for `chat`, wired to the same work as the op. The sheet is the
    /// owner's own: what they do in it needs no consent sheet.
    static func inviteSheet(_ chat: AgentShareChat, role: String, host: any AgentShareHost) -> AgentShareInviteSheetModel {
        AgentShareInviteSheetModel(chat: chat.title, session: chat.session, role: role, work: AgentShareInviteSheetModel.Work(
            list: { try await Self.connected(chat.connection).request(AgentSessionShareListRequest(surface: chat.surface)).shares },
            invite: { account, role in _ = try await Self.inviteWork(chat, account: account, role: role, ttl: nil, host: host) },
            remove: { account in _ = try await Self.uninviteWork(account: account, shareID: nil, chat: chat, connection: chat.connection) },
            copy: { host.shareCopy($0) }
        ))
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
        inviteRecord(of: session, in: shares)?.shareId
    }

    /// The link of the share invites to `session`'s chat go on (``inviteShare(of:in:)``); nil with none,
    /// or while that share has no room.
    static func inviteLink(of session: String, in shares: [AgentSessionShare]) -> String? {
        inviteRecord(of: session, in: shares)?.inviteUrl
    }

    private static func inviteRecord(of session: String, in shares: [AgentSessionShare]) -> AgentSessionShare? {
        shares.filter { $0.session == session && $0.isLive && !$0.invitees.isEmpty }.max { $0.createdAt < $1.createdAt }
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

extension AgentShareInvites {
    /// The sheet's people: every account still invited on a live share of `session`'s chat, once
    /// each (its latest invite), oldest first, and whether a device of it is in the chat now.
    static func rows(of session: String, in shares: [AgentSessionShare]) -> [AgentShareInviteSheetModel.Row] {
        let live = shares.filter { $0.session == session && $0.isLive }
        var latest: [String: AgentSessionShareInvitee] = [:]
        for invitee in live.flatMap(\.invitees) where invitee.isInvited {
            if let seen = latest[invitee.account], seen.invitedAt >= invitee.invitedAt { continue }
            latest[invitee.account] = invitee
        }
        let joined = Set(live.flatMap(\.guests).filter { $0.state == "active" }.compactMap(\.account))
        return latest.values.sorted { ($0.invitedAt, $0.account) < ($1.invitedAt, $1.account) }.map {
            AgentShareInviteSheetModel.Row(account: $0.account, role: $0.role, joined: joined.contains($0.account))
        }
    }
}

/// `share uninvite` named an account no share of the chat invites.
struct AgentShareNotInvited: Error, Equatable {
    var account: String
}
