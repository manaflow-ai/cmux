import CmuxNextDaemon
import Foundation

/// Native confirmation and account binding for a team share. Membership and admission policy stay
/// in the hosted room and Rust daemon; the app only presents the authorized team and mints its token.
@MainActor
struct AgentShareTeamConsent {
    let team: AgentShareTeam
    let accountScope: String

    func requireCurrent(chat: AgentShareChat, host: any AgentShareHost) throws {
        guard host.shareAccountScope == accountScope, host.shareTeams.contains(team),
              let tabID = host.shareTabID(showing: chat.session), let tab = host.shareTab(id: tabID),
              AgentShareChat.session(of: tab) == chat.session, tab.surface.rawValue == chat.surface,
              host.shareConnection(holding: tab) === chat.connection else { throw AgentShareTeamUnavailable() }
    }
}

extension AgentShareActions {
    static func confirmTeam(_ id: String, role: String, chat: AgentShareChat,
                            host: any AgentShareHost) async throws -> AgentShareTeamConsent {
        guard let scope = host.shareAccountScope, let team = host.shareTeams.first(where: { $0.id == id }) else {
            throw AgentShareTeamUnavailable()
        }
        let consent = AgentShareTeamConsent(team: team, accountScope: scope)
        try consent.requireCurrent(chat: chat, host: host)
        let ask = AgentShareConsentAsk(chat: chat.title, ttlSecs: nil, uses: nil, team: team, teamRole: role)
        guard await host.shareAskOwner(ask) else { throw AgentShareDeclined() }
        try consent.requireCurrent(chat: chat, host: host)
        return consent
    }
}

struct AgentShareTeamUnavailable: Error {}
