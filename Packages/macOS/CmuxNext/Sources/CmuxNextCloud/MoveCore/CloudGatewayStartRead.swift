public import Foundation
public import os

/// The start gate's gateway read (``CloudSetup/gateway``; hq#15762): what the gateways of the teams a start's machine
/// can be made in serve now, each read logged with why it gave nothing. A team in inference gateway mode, its gateway
/// online, serves a chat with no connection of the person's own. The teams are the install token's and the person's
/// own (``CloudMoveCLI/inferenceGatewayServes(teams:)``), never the active team's. The install token waits for this
/// launch's bind, as the relay's does: a start right after launch otherwise read no team and refused ("No Cloud
/// connection serves claude yet") with the gateway online (hq cloud-chat-works, production 2026-11-23 00:03Z and
/// 00:34Z). A failed token still reads the person's own team.
public extension CloudMoveCLI {
    private static let startLog = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.start")

    func inferenceGatewayServes(identity: MacInstallIdentity, personalTeam: String?, bindWait: Duration = .seconds(8)) async -> Set<String>? {
        let log = Self.startLog
        var installTeam: String?
        do {
            installTeam = MacInstallIdentity.team(ofToken: try await identity.installToken(awaitingBind: bindWait))
            if installTeam == nil { log.error("cloud start gate: the install token names no team") }
        } catch {
            log.error("cloud start gate: install team unread: install token: \(String(describing: error), privacy: .public)")
        }
        var asked: Set<String> = [], serves: Set<String>?
        for team in [installTeam, personalTeam].compactMap({ $0 }) where asked.insert(team).inserted {
            let read = await inferenceGatewayRead(team: team)
            if let answer = read.serves {
                log.info("cloud start gate: team \(team, privacy: .public) gateway serves [\(answer.sorted().joined(separator: ","), privacy: .public)]")
                serves = (serves ?? []).union(answer)
            } else {
                log.error("cloud start gate: team \(team, privacy: .public) gateway unread: \(read.why ?? "-", privacy: .public)")
            }
        }
        if asked.isEmpty { log.error("cloud start gate: gateway unread: no team to ask") }
        return serves
    }
}
