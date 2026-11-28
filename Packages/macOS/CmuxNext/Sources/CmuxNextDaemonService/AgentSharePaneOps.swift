import CmuxNextActions
public import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The agent chat's Share dialog (`share.op`, ``AgentPaneShareOp``): the same daemon work as
/// `agent.share`, `-.invite`, `-.uninvite` and `-.revoke`, always on the chat of the pane that
/// asked. The pane gated a link or an invite on the person's click in their own chat, which is the
/// owner's consent. Team access additionally requires native confirmation. `manage` opens Settings.
extension AgentShareActions {
    /// The dialog's link lasts a week and works for anyone who has it (bounded by the daemon).
    static let paneLinkTTL: UInt64 = 604_800
    static let paneLinkUses: UInt32 = 1000
    /// Manage links…: Settings > Privacy and Security at its Shared Links card.
    public static let sharedLinksRoute = "#/settings/privacy?focus=card.sharedLinks"
    /// Why the dialog can do nothing here: this tab shows no started agent chat on this Mac.
    public static var paneUnavailable: String { AgentShareStrings.notAChat }

    /// One dialog op on the chat tab `tab` shows. Refused `unavailable` when that tab no longer shows
    /// a started agent chat on this Mac.
    /// `pinned`: the chat the dialog opened on, when the page named it; the tab must still show it,
    /// and it is the daemon's session pin on create and invite (`share.chat_moved` past that).
    public static func pane(_ op: AgentPaneShareOp, session pinned: String? = nil, tab: String,
                            host: any AgentShareHost) async -> AgentPaneShareReply {
        // Manage links… opens Settings at its Shared links card, whatever the tab shows.
        if op == .manage {
            host.shareOpenSettings(route: sharedLinksRoute)
            return .value([:])
        }
        guard let found = host.shareTab(id: tab), let session = AgentShareChat.session(of: found) else {
            return .refused(code: "unavailable", message: paneUnavailable)
        }
        let isLocal = host.shareIsOnThisMac(found)
        let cloudOwner = isLocal ? nil : host.shareCloudOwner(found)
        guard isLocal || cloudOwner != nil else { return .refused(code: "unavailable", message: paneUnavailable) }
        if let pinned, pinned != session {
            return .refused(code: "unavailable", message: AgentShareStrings.reason("share.chat_moved") ?? paneUnavailable)
        }
        let chat = AgentShareChat(surface: found.surface.rawValue, session: session, connection: host.shareConnection(holding: found),
                                  isLocal: isLocal, title: found.titleText, cloudOwner: cloudOwner)
        do {
            switch op {
            case .state:
                let listed = try await connected(chat.connection).request(AgentSessionShareListRequest(surface: chat.surface))
                return .value(["shares": AgentSharePaneState.shares(of: chat.session, in: listed.shares),
                               "teams": host.shareTeams.map { ["id": $0.id, "name": $0.name] }])
            case .link(let role):
                let created = try await create(chat, ttl: paneLinkTTL, uses: paneLinkUses, role: role, host: host)
                return .value(["shareId": created.shareId, "url": created.url ?? NSNull(), "expiresAt": Int(clamping: created.expiresAt)])
            case .team(let teamID, let role):
                let created = try await create(chat, ttl: paneLinkTTL, uses: nil, role: role, team: teamID, host: host)
                return .value(["shareId": created.shareId, "inviteUrl": created.url ?? NSNull(), "expiresAt": Int(clamping: created.expiresAt)])
            case .invite(let account, let role):
                let result = try await inviteWork(chat, account: account, role: role, ttl: nil, host: host)
                return .value(["inviteUrl": AgentShareInvites.text(result["invite_url"]) ?? NSNull()])
            case .uninvite(let account):
                _ = try await uninviteWork(account: account, shareID: nil, chat: chat, connection: chat.connection)
                return .value(["account": account])
            case .approve(let account, let role):
                let connection = try connected(chat.connection)
                let asked = try await askedShares(account, chat: chat, connection: connection)
                for share in asked {
                    _ = try await connection.request(AgentSessionShareRequestApproveRequest(shareId: share, account: account, role: role))
                }
                return .value(["account": account, "role": role])
            case .decline(let account):
                let connection = try connected(chat.connection)
                for share in try await askedShares(account, chat: chat, connection: connection) {
                    _ = try await connection.request(AgentSessionShareRequestDeclineRequest(shareId: share, account: account))
                }
                return .value(["account": account])
            case .revoke(let shareID):
                let connection = try connected(chat.connection)
                let listed = try await connection.request(AgentSessionShareListRequest(surface: chat.surface))
                // Only a share of this chat: the page never ends another chat's link.
                guard AgentSharePaneState.isShare(shareID, of: chat.session, in: listed.shares) else {
                    return .refused(code: "share.unknown", message: AgentShareStrings.reason("share.unknown") ?? "share.unknown")
                }
                _ = try await connection.request(AgentSessionShareRevokeRequest(shareId: shareID))
                return .value(["shareId": shareID])
            case .manage:
                return .value([:])
            }
        } catch {
            let failure = AgentShareStrings.failure(error)
            return .refused(code: failure.code ?? "unavailable", message: failure.shownReason ?? failure.message)
        }
    }
}

extension AgentShareActions {
    /// This chat's live shares on which `account` has a pending request; `share.unknown` when none
    /// (the page's row was stale).
    static func askedShares(_ account: String, chat: AgentShareChat, connection: DaemonConnection) async throws -> [String] {
        let listed = try await connection.request(AgentSessionShareListRequest(surface: chat.surface))
        let asked = AgentSharePaneState.sharesAsked(by: account, of: chat.session, in: listed.shares)
        guard !asked.isEmpty else { throw AgentShareRequestGone() }
        return asked
    }
}

/// An approve or decline whose account has no pending request on this chat any more.
struct AgentShareRequestGone: Error {}

/// What the dialog's `state` answers: this chat's shares in the page's camelCase keys (the link's
/// secret is never kept, so `url` is always null).
enum AgentSharePaneState {
    static func isShare(_ shareID: String, of session: String, in shares: [AgentSessionShare]) -> Bool {
        shares.contains { $0.shareId == shareID && $0.session == session }
    }

    /// The live shares of `session` on which `account` (compared as the daemon keeps it: trimmed,
    /// lowercased) has a pending request.
    static func sharesAsked(by account: String, of session: String, in shares: [AgentSessionShare]) -> [String] {
        let wanted = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return shares.filter { share in
            share.session == session && share.isLive && share.requests.contains { $0.account == wanted && $0.state == "pending" }
        }.map(\.shareId)
    }

    static func shares(of session: String, in shares: [AgentSessionShare]) -> [[String: Any]] {
        shares.filter { $0.session == session }.map { share in
            let joined = Set(share.guests.filter { $0.state == "active" }.compactMap(\.account))
            return [
                "shareId": share.shareId, "state": share.state, "url": NSNull(), "inviteUrl": share.inviteUrl ?? NSNull(),
                "role": share.role ?? NSNull(), "createdAt": Int(clamping: share.createdAt), "expiresAt": Int(clamping: share.expiresAt),
                "usesLeft": Int(share.usesLeft), "teamId": share.teamId ?? NSNull(),
                "guests": share.guests.map { guest -> [String: Any] in
                    ["guestId": guest.guestId, "name": guest.name, "account": guest.account ?? NSNull(), "role": guest.role ?? NSNull(),
                     "joined": guest.state == "active"]
                },
                "invitees": share.invitees.map { invitee -> [String: Any] in
                    ["account": invitee.account, "role": invitee.role, "state": invitee.state, "joined": joined.contains(invitee.account)]
                },
                "requests": share.requests.filter { $0.state == "pending" }.map { request -> [String: Any] in
                    ["account": request.account, "name": request.name, "avatarUrl": request.avatarUrl ?? NSNull(),
                     "requestedAt": Int(clamping: request.requestedAt)]
                },
            ]
        }
    }
}
