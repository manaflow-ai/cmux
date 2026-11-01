import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextMobile

extension AppServices {
    /// Forward current app-link facts to Rust hostd. Classic links never enter this directory.
    func phoneCloudLinks() async -> [MobileHostCloudLink] {
        guard cloud.auth.isSignedIn, let user = cloud.auth.user?.id else { return [] }
        let selectedTeam = cloud.auth.teamID
        // The backend team in attention events is the install token claim, not a Stack team id.
        guard let token = try? await cloud.installIdentity.installToken(),
              let team = MacInstallIdentity.team(ofToken: token) else { return [] }
        var result: [MobileHostCloudLink] = []
        for session in machines.cloud {
            guard let link = session.appLink, let socket = await link.currentLinkSocket,
                  machines.session(session.machineID) === session else { continue }
            result.append(MobileHostCloudLink(machineID: socket.key.machine, teamID: team,
                                              name: session.machine.shownName ?? session.machineID,
                                              socket: socket.path, owner: socket.callerOwnsVM))
        }
        // An account transition during either actor hop invalidates the whole answer.
        guard cloud.auth.isSignedIn, cloud.auth.user?.id == user, cloud.auth.teamID == selectedTeam else { return [] }
        return result
    }
}
