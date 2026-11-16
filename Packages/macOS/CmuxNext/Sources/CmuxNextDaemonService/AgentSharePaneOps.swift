import CmuxNextActions
public import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The agent chat's Share dialog (`share.op`, ``AgentPaneShareOp``): the same daemon work as
/// `agent.share`, `-.invite`, `-.uninvite` and `-.revoke`, always on the chat of the pane that
/// asked. The pane gated a link or an invite on the person's click in their own chat, which is the
/// owner's consent, so no consent sheet is shown. `manage` is the app's (it opens Settings).
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
        guard let found = host.shareTab(id: tab), let session = AgentShareChat.session(of: found), host.shareIsOnThisMac(found) else {
            return .refused(code: "unavailable", message: paneUnavailable)
        }
        if let pinned, pinned != session {
            return .refused(code: "unavailable", message: AgentShareStrings.reason("share.chat_moved") ?? paneUnavailable)
        }
        let chat = AgentShareChat(surface: found.surface.rawValue, session: session, connection: host.shareConnection(holding: found),
                                  isLocal: true, title: found.titleText)
        do {
            switch op {
            case .state:
                let listed = try await connected(chat.connection).request(AgentSessionShareListRequest(surface: chat.surface))
                return .value(["shares": AgentSharePaneState.shares(of: chat.session, in: listed.shares)])
            case .link(let role):
                let created = try await create(chat, ttl: paneLinkTTL, uses: paneLinkUses, role: role, host: host)
                return .value(["shareId": created.shareId, "url": created.url ?? NSNull(), "expiresAt": Int(clamping: created.expiresAt)])
            case .invite(let account, let role):
                let result = try await inviteWork(chat, account: account, role: role, ttl: nil, host: host)
                return .value(["inviteUrl": AgentShareInvites.text(result["invite_url"]) ?? NSNull()])
            case .uninvite(let account):
                _ = try await uninviteWork(account: account, shareID: nil, chat: chat, connection: chat.connection)
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

/// What the dialog's `state` answers: this chat's shares in the page's camelCase keys (the link's
/// secret is never kept, so `url` is always null).
enum AgentSharePaneState {
    static func isShare(_ shareID: String, of session: String, in shares: [AgentSessionShare]) -> Bool {
        shares.contains { $0.shareId == shareID && $0.session == session }
    }

    static func shares(of session: String, in shares: [AgentSessionShare]) -> [[String: Any]] {
        shares.filter { $0.session == session }.map { share in
            let joined = Set(share.guests.filter { $0.state == "active" }.compactMap(\.account))
            return [
                "shareId": share.shareId, "state": share.state, "url": NSNull(), "inviteUrl": share.inviteUrl ?? NSNull(),
                "role": share.role ?? NSNull(), "createdAt": Int(clamping: share.createdAt), "expiresAt": Int(clamping: share.expiresAt),
                "usesLeft": Int(share.usesLeft),
                "guests": share.guests.map { guest -> [String: Any] in
                    ["guestId": guest.guestId, "name": guest.name, "account": guest.account ?? NSNull(), "role": guest.role ?? NSNull(),
                     "joined": guest.state == "active"]
                },
                "invitees": share.invitees.map { invitee -> [String: Any] in
                    ["account": invitee.account, "role": invitee.role, "state": invitee.state, "joined": joined.contains(invitee.account)]
                },
            ]
        }
    }
}
