import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief

/// Every Chief in the Home list on every host, one tagged Main (Lawrence
/// 2026-10-19: "idk which is main one"; 2026-10-20: "local chiefs and cloud
/// chiefs and mac mini chiefs etc all at the same time").
extension HomeService {
    /// The Home list's Chiefs: all of them, the main one on the host the user picked.
    var chiefRoster: HomeChiefRoster {
        let live = liveChiefRoster
        // Until the cloud Chiefs are read, the last launch's Main and places (HomeService+LaunchList).
        guard !cloudChiefsRead, let last = launchRoster else { return live }
        return live.launching(last: last)
    }

    private var liveChiefRoster: HomeChiefRoster {
        let tab = tabChiefs
        let rows: [InboxRow] = homeStore.rows
        let chiefRows = rows.filter { $0.kind == .chief }
        let cloud = Set(chiefRows.filter { homeStore.summary($0.id)?.owner == .cloud }.map(\.id))
        let localID: String? = HomeChiefName.select(from: conversations)?.id
        let local = localID.map { CmuxHomeCore.ConversationID($0) }
        let hosted = tab.hosted?.mainConversation.map { CmuxHomeCore.ConversationID($0) }
        let placed = tab.placed?.mainConversation.map { CmuxHomeCore.ConversationID($0) }
        return HomeChiefRoster.make(rows: rows, local: local, hosted: hosted, placed: placed, server: serverName(of: tab.placed),
                                    showsPlaced: hostedChief.choice == .placed, cloud: cloud)
    }

    /// Where `conversation`'s cloud Chief runs and its other host, for the Chief's card.
    func chiefHost(of conversation: String) -> HomeChiefHostLine {
        let tab = tabChiefs
        let server = HomeChiefPlace.server(serverName(of: tab.placed) ?? HomeChiefPlace.cloud.label).label
        var line = HomeChiefHostLine()
        if conversation == tab.hosted?.mainConversation { line.place = HomeEngineStrings.runsInCloud }
        if conversation == tab.placed?.mainConversation { line.place = String(format: HomeEngineStrings.runsOnFormat, server) }
        switch tab.otherHost(of: conversation) {
        case .placed: line.switchTo = server
        case .hosted: line.switchTo = HomeChiefPlace.cloud.label
        case nil: break
        }
        return line
    }

    /// The cloud Chief whose main conversation is `conversation` (``HomeCloudChiefs/placement(of:records:)``).
    func cloudChiefPlacement(of conversation: String) -> (id: String, placed: Bool)? {
        cloudChiefs.placement(of: conversation, records: directory.chiefs)
    }

    /// The paired server's name for a placed Chief (its host id while the server is not paired here).
    func serverName(of chief: CloudChief?) -> String? {
        guard let host = chief?.brainPlace?.host else { return nil }
        return services.machines.servers.first { $0.reach.hostID == host }?.name ?? host
    }
}
