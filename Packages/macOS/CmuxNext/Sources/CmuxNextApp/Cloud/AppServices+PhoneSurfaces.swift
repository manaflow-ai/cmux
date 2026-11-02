import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextMobile
import CmuxNextMobileHost
import CmuxNextPhone
import Foundation

extension AppServices {
    /// What hostd's `surface` service streams from this Mac: phone tabs `s<surface>` as streamed
    /// simulators (``SimulatorSurfaceSources``, when SimulatorKit can load), and the owner's Cloud
    /// desktops `c~<machine>~<team>` view only (``PhoneCloudDesktopSources``). Never nil: a Cloud
    /// desktop can stream on any Mac (each start checks the account, the machine and the tunnel),
    /// so hostd serves `surface` and says `cloud-desktop-v1` without a simulator too.
    func phoneSurfaceHosts() -> any MobileHostSurfaceHosting {
        var simulators: SimulatorSurfaceSources?
        if SimulatorSurfaceSources.available(phones) {
            simulators = SimulatorSurfaceSources(phones: phones) { [weak self] raw in
                guard let self, let tab = self.daemon.store.tab(surface: SurfaceID(rawValue: raw)),
                      tab.page == InternalPageID.phone.rawValue else { return nil }
                let route = self.pages.storeKey(of: tab.id).flatMap { (self.pages.provider(.phone) as? PhonePageTab)?.route(for: $0) }
                return .some((route ?? tab.pageRoute).flatMap { PhoneDeviceID($0) })
            }
        }
        let phoneTabs = simulators
        let desktops = PhoneCloudDesktopSources(services: self)
        return MobileHostSurfaceClosures(start: { tab, onExit in
            if PhoneCloudDesktopSources.target(of: tab) != nil { return try await desktops.start(tab: tab, onExit: onExit) }
            guard let phoneTabs else { throw SimulatorSurfaceSources.Failure.notPhoneTab }
            return try await phoneTabs.start(tab: tab, onExit: onExit)
        }, stop: { tab in
            if PhoneCloudDesktopSources.target(of: tab) != nil { await desktops.stop(tab: tab) } else { await phoneTabs?.stop(tab: tab) }
        }, stopAll: {
            await desktops.stopAll()
            await phoneTabs?.stopAll()
        })
    }

    /// Forward the account's Cloud machines to Rust hostd: each machine with an app link, with its
    /// live link socket when there is one (none: asleep), and whether the plan pays for Cloud.
    /// Classic links never enter this directory; destroyed and deleting machines are left out.
    func phoneCloudLinks() async -> MobileHostCloudLinks {
        guard cloud.auth.isSignedIn, let user = cloud.auth.user?.id else { return MobileHostCloudLinks() }
        let selectedTeam = cloud.auth.teamID
        // The backend team in attention events is the install token claim, not a Stack team id.
        guard let token = try? await cloud.installIdentity.installToken(),
              let team = MacInstallIdentity.team(ofToken: token) else { return MobileHostCloudLinks() }
        var result: [MobileHostCloudLink] = []
        for session in machines.cloud {
            guard let link = session.appLink, machines.session(session.machineID) === session,
                  !session.machine.isGoneForPhones else { continue }
            let socket = await link.currentLinkSocket
            guard machines.session(session.machineID) === session else { continue }
            let machine = session.machine
            guard !machine.isGoneForPhones else { continue }
            // Ownership: a live link carries the Cloud API's caller-relative answer (`vmKind == "owner"`).
            // Without one, the machine record's creator is the only owner signal this Mac holds; the
            // attach answer gives a machine's creator `owner` too (#28788). A record without a creator
            // is never owned here, so hostd never serves a teammate's machine as the caller's.
            let owner = socket?.callerOwnsVM ?? (machine.createdBy == user)
            result.append(MobileHostCloudLink(machineID: socket?.key.machine ?? session.machineID, teamID: team,
                                              name: machine.shownName ?? session.machineID, socket: socket?.path,
                                              owner: owner, status: machine.shownStatus.rawValue, ran: machine.hasRun))
        }
        // An account transition during either actor hop invalidates the whole answer.
        guard cloud.auth.isSignedIn, cloud.auth.user?.id == user, cloud.auth.teamID == selectedTeam else { return MobileHostCloudLinks() }
        return MobileHostCloudLinks(paid: machines.cloudLimits?.paysForCloud ?? false, links: result)
    }
}
