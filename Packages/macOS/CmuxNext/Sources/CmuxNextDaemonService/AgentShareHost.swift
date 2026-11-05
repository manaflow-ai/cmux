public import CmuxNextDaemon
public import Foundation

/// What Share with Guest and Invite People need from the app (design chat-multiplayer.md 1 and 6): the chat tabs a
/// run can name, the daemon each lives on, the owner's cmux install token and where a person's run
/// says the link was copied. The App conforms with one-line forwards (`AppServices+AgentShareHost`).
@MainActor
public protocol AgentShareHost: AnyObject {
    /// The tab on this Mac's daemon surface `surface`.
    func shareTab(surface: SurfaceID) -> TabModel?
    /// The tab with id or resource id `id`, on any machine.
    func shareTab(id: String) -> TabModel?
    /// The id of the tab that shows acpmux session `session` (the chat whose agent ran the CLI).
    func shareTabID(showing session: String) -> String?
    /// The id of the focused pane's selected tab.
    var shareFocusedTabID: String? { get }
    /// The connection of the daemon that holds `tab`; nil when that machine is not connected.
    func shareConnection(holding tab: TabModel) -> DaemonConnection?
    /// Whether `tab` is on this Mac's daemon, the only one that makes and lists shares.
    func shareIsOnThisMac(_ tab: TabModel) -> Bool
    /// This Mac's daemon connection (list, revoke and kick act on this Mac's shares).
    var shareLocalConnection: DaemonConnection? { get }
    /// A fresh cmux install token of the signed-in owner (`/v1/auth/token`, ES256) from `api`, the API the
    /// daemon's share room takes tokens from (nil: the daemon did not say, the build's default); nil signed out.
    func shareOwnerToken(api: URL?) async -> String?
    /// Puts `text` on the general pasteboard.
    func shareCopy(_ text: String)
    /// Shows a person's run `message` as a notice in the active window.
    func shareNotice(_ message: String)
    /// Asks the owner in the app whether a run they did not start (an agent's, a script's, the CLI's)
    /// may make a guest link to `ask.chat` (#30263); answers whether they allowed it. A host that
    /// cannot ask answers no.
    func shareAskOwner(_ ask: AgentShareConsentAsk) async -> Bool
    /// Shows the Invite People sheet of one chat over the active window (the owner's own run of
    /// Invite People… with no account named).
    func shareShowInvites(_ model: AgentShareInviteSheetModel)
}

public extension AgentShareHost {
    /// Fail closed: a host with no consent sheet never lets automation make a link.
    func shareAskOwner(_ ask: AgentShareConsentAsk) async -> Bool { false }
    /// A host with no sheet shows nothing.
    func shareShowInvites(_ model: AgentShareInviteSheetModel) {}
}

/// What the owner is asked before a run they did not start makes a guest link, or invites an account:
/// the chat, and how long the link lasts and how many times it works, or who is invited and what they
/// may do. Its sentences are the consent sheet's (AgentShare.xcstrings).
public struct AgentShareConsentAsk: Sendable, Hashable {
    /// The account an invite names, and its role (`view` or `talk`).
    public struct Invite: Sendable, Hashable {
        public var account: String
        public var role: String

        public init(account: String, role: String) {
            self.account = account
            self.role = role
        }
    }

    /// The chat's tab title.
    public var chat: String
    /// The link's lifetime in seconds; nil is the daemon's default (24 hours).
    public var ttlSecs: UInt64?
    /// How many times the link works; nil is the daemon's default (once).
    public var uses: UInt32?
    /// Set for an invite (`agent.share.invite`); nil for a guest link.
    public var invite: Invite?

    public init(chat: String, ttlSecs: UInt64?, uses: UInt32?, invite: Invite? = nil) {
        self.chat = chat
        self.ttlSecs = ttlSecs
        self.uses = uses
        self.invite = invite
    }

    public var title: String {
        invite.map { AgentShareStrings.inviteConsentTitle($0.account, chat: chat) } ?? AgentShareStrings.consentTitle(chat)
    }
    public var lines: [String] {
        if let invite { return [AgentShareStrings.inviteConsentDetail, AgentShareStrings.inviteRoleLine(invite.role)] }
        return [AgentShareStrings.consentDetail, AgentShareStrings.consentTerms(ttlSecs: ttlSecs ?? 86400, uses: uses ?? 1)]
    }
    public var allowTitle: String { invite == nil ? AgentShareStrings.consentAllow : AgentShareStrings.inviteConsentAllow }
    public var declineTitle: String { invite == nil ? AgentShareStrings.consentDecline : AgentShareStrings.inviteConsentDecline }
    /// The Feed request's button that brings this Mac's sheet forward (it never allows a link).
    public var showOnMacTitle: String { AgentShareStrings.consentShowOnMac }
}
