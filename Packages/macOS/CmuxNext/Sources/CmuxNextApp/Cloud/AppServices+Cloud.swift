import CmuxNextActions
import CmuxNextCompat
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextPhone
import CmuxNextMobile
import CmuxNextMobileHost
import CmuxNextPhoneAccess
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import CmuxNextRemoteView
import CmuxNextRemoteViewSessions
import Foundation
import Observation

extension AppServices {
    /// The loopback port of a Cloud machine's `cmux-rd` desktop host (`--port`).
    static let cloudDesktopRdPort: UInt16 = 4103

    /// Open Desktop's `cmux-rd` viewer: Cloud machine `machine`'s desktop host on its private
    /// address, reached over the app's token-gated Cloud tunnel, with the session token Open
    /// Desktop fetched (read again for every session, so a Reconnect after Open Desktop fetched a
    /// new one uses it). `control` is the tab's mode: a tab
    /// someone confirmed from a Connect card asks for view only. Nil without the machine or token.
    func cloudDesktopRdTransport(machine: String, control: Bool) -> (@MainActor () -> RemoteRdStreamTransport?)? {
        let key = machine.lowercased()
        guard let id = machines.cloud.first(where: { $0.machineID.lowercased() == key })?.machineID,
              cloud.desktopRdTokens[key] != nil else { return nil }
        // Over the Cloud tunnel to the host on the machine's private address (it needs nothing from
        // the machine's daemon, so any machine with the host works), not the daemon link.
        guard let hub = remoteLocalhost.cloudTunnelSocket, let address = machines.cloudTunnelAddress(machine: id),
              let opener = HubLoopbackOpener(hub: hub, address: address) else { return nil }
        let cloud = cloud
        return {
            guard let token = cloud.desktopRdTokens[key] else { return nil }
            let hello = RemoteRdHello(user: "cmux", install: "cmux-next-\(ProcessInfo.processInfo.processIdentifier)", token: token)
            let carrier = RemoteRdStreamCarrier {
                let tunnel = try await opener.openTunnel(host: "localhost", port: Self.cloudDesktopRdPort)
                let reader = LoopbackTunnelReader(tunnel)
                return RemoteRdByteStream(read: { try? await reader.read() }, write: { try await tunnel.write($0) },
                                          close: { tunnel.close() })
            }
            return RemoteRdStreamTransport(carrier: carrier, hello: hello, startKey: UUID().uuidString, control: control)
        }
    }

    /// Open Desktop's native viewer: Cloud machine `machine`'s websockify port (6901, next to its
    /// noVNC) over this Mac's own Cloud tunnel, with the hub's client token; no port opens on this
    /// Mac. Nil when the tunnel cannot reach it (signed out, the machine without an address).
    func cloudDesktopTransport(machine: String) -> (@Sendable () async throws -> RemoteViewPageSession.CloudDesktopStream)? {
        guard let hub = remoteLocalhost.cloudTunnelSocket, let address = machines.cloudTunnelAddress(machine: machine),
              let opener = HubLoopbackOpener(hub: hub, address: address) else { return nil }
        return {
            let tunnel = try await opener.openTunnel(host: "localhost", port: 6901)
            let reader = LoopbackTunnelReader(tunnel)
            return RemoteViewPageSession.CloudDesktopStream(read: { try await reader.read() },
                                                            write: { try await tunnel.write($0) },
                                                            close: { tunnel.close() })
        }
    }

    /// The daemon handlers command: while an action runs, the machine that
    /// owns its explicit target (`ActionRouting`); otherwise the active
    /// window's machine (the local daemon, or its Cloud machine).
    var activeDaemon: DaemonService {
        if let routedDaemon { return routedDaemon }
        guard let machine = windows.active?.state.machineID else { return daemon }
        // A window of a machine turned off by policy (DisabledFeatures) keeps
        // its blocked daemon: commands fail there, never land on this Mac.
        return machines.daemon(machine: machine) ?? machines.anyDaemon(machine: machine) ?? daemon
    }

    /// Publishes `signedIn` / `signedOut` / `cloudWorkspace` to the action
    /// registry. `cloudWorkspace` means the active window shows a Cloud
    /// machine's workspace, so the palette offers machine actions for it.
    /// An explicit `machine:` target satisfies it too
    /// (`ActionContext.implied(by:)`), so the CLI and a right-click on a
    /// machine header work from any window.
    func cloudContextDidChange() {
        var context = registry.context
        let signedIn = cloud.isSignedIn
        context.remove([.signedIn, .signedOut, .cloudWorkspace])
        context.insert(signedIn ? .signedIn : .signedOut)
        if signedIn, let machine = windows.active?.state.machineID, machines.session(machine) != nil {
            context.insert(.cloudWorkspace)
        }
        #if DEBUG
        // `debug.cloud_machine_fixture`: a capture's Cloud machine header, with no session or sign-in.
        if debugFixtures.holdsCloudWorkspace { context.insert(.cloudWorkspace) }
        #endif
        if registry.context != context { registry.context = context }
    }

    /// Starts Cloud and keeps the registry context current.
    func startCloud() -> Task<Void, Never> {
        // An agent's request waits in the sidebar card; with the active window's sidebar hidden it takes the sheet, so it never waits unseen.
        // The plan gate's Upgrade takes the one paid-plan path (PaidPlanUpgrade): Checkout that returns here, else pricing.
        cloud.confirmCreate = { [weak self] in await CloudPresenter.confirmCreate($0, in: self?.windows.active?.window, asks: self?.windows.active?.state.sidebarHidden == false ? self?.machineAsks : nil, chatOpen: { [weak self] in self?.agentTabs.tab(showing: $0) != nil },
                                                                           openPricing: { [weak self] _ in Task { await self?.paidPlanUpgrade().start(source: .cloudCreate) } }) }
        cloud.planObserved = { [weak self] in self?.paidPlanObserved($0) }
        cloud.start()
        // Each Cloud machine follows the app's cmux-tui build by itself, also while an agent works there.
        CloudMachineUpdates.start(self)
        iphone.pairedQuitRecord = agentPaneStateLoss
        iphone.wire(auth: cloud.auth, daemon: daemon, acpmuxHost: { [weak self] in self?.agentTabs.host }, acpmuxEnvironment: QuitAgents.environment(self),
                    agentTabHost: { [weak self] in self?.agentTabs.localHost },
                    newChatPicks: { [weak self] in NewChatPicks(lastAgent: self?.newTabChoices.agent, picks: self?.newTabChoices.picks) },
                    chief: { [weak self] in if let owner = self?.home.chief { IPhoneHostService.ChiefPlacement(session: owner.home.session, socket: await owner.socketPath()) } else { nil } },
                    surfaceHosts: phoneSurfaceHosts(),
                    cloudLinks: { [weak self] in await self?.phoneCloudLinks() ?? MobileHostCloudLinks() },
                    settings: { [weak self] in self?.settings },
                    bundleID: environment.launch.bundleID, computerName: { await MacName().computerName() })
        iphone.pairWindow = { [weak self] in self?.windows.active?.window }
        iphone.pairNotices = IPhonePairNotices(post: { [weak self] in self?.notifications.desktop.post(id: IPhonePairNotices.id, title: $0,
            body: $1, surface: nil, workspace: nil, defaultSound: true, category: IPhonePairNotices.category) },
            withdraw: { [weak self] in self?.notifications.desktop.withdraw([IPhonePairNotices.id]) })
        let cloud = cloud, machines = machines
        return Task { [weak self] in
            var account: (user: String, team: String)?
            var routerUser: String??
            for await state in ObservationStream({ (cloud.isSignedIn, machines.cloud.count, cloud.auth.user?.id, cloud.auth.teamID) }) {
                guard let self else { return }
                self.cloudContextDidChange()
                self.agentTabs.syncCloudCredentialTransferAvailability(services: self)
                // The local model relay follows the signed-in user (ModelRouterLease).
                let user = state.0 ? state.2 : nil
                if routerUser != .some(user) {
                    routerUser = .some(user)
                    self.modelRouter?.accountChanged(user)
                }
                // Phone access follows the account: start after sign-in, restart on a user or team switch,
                // stop on sign-out. A switch of the active team also reloads the team's machines and accounts.
                let current = state.0 ? state.2.flatMap { user in state.3.map { (user: user, team: $0) } } : nil
                guard current?.user != account?.user || current?.team != account?.team else { continue }
                // task-owner: one machine-list reload; CloudService reconciles.
                if let before = account, before.user == current?.user { Task { await cloud.refresh() }; self.accounts.model.refresh() }
                account = current
                if let auth = CloudMobileAuth(auth: cloud.auth) {
                    self.mobile.start(auth: auth, launch: self.environment.launch, daemon: self.daemon)
                } else {
                    self.mobile.stop()
                }
            }
        }
    }
}
