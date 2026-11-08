import CmuxNextActions
import CmuxNextCompat
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextPhone
import CmuxNextMobile
import CmuxNextMobileHost
import CmuxNextPhoneAccess
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
import CmuxNextRemoteView
import CmuxNextRemoteViewSessions
import CmuxNextSettings
import Foundation
import Observation

extension AppServices {
    /// Open Desktop's `cmux-rd` viewer: the machine's desktop host over the carrier, a new
    /// `cmux carrier dial --service desktop` per session with the platform origin and the person's
    /// access token (``CloudCarrierDial/Connector``, ended with the account); each session's transport in the mode it asks for.
    func cloudDesktopRdTransport(machine: String) -> (@MainActor (_ control: Bool) -> RemoteRdStreamTransport?)? {
        guard cloud.auth.isSignedIn, !cloud.policyDisabled, let session = machines.cloud.first(where: { $0.machineID.lowercased() == machine.lowercased() }),
              let dial = CloudCarrierDial.Connector(machine: session.machineID, service: .desktop, cli: cloud.binary, auth: cloud.auth, platform: cloud.configuration.relayAPIBaseURL(),
                                                    team: session.machine.team, stateDirectory: cloud.tuiState, streams: cloud.desktopStreams) else { return nil }
        return { control in
            let carrier = RemoteRdStreamCarrier {
                let stream = try await dial.open()
                return RemoteRdByteStream(read: { await stream.read() }, write: { try await stream.send($0) }, close: { stream.close() })
            }
            return RemoteRdStreamTransport(carrier: carrier, hello: RemoteRdHello.cloudDesktop(), startKey: UUID().uuidString, control: control)
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
        cloud.confirmCreate = { [weak self] in await CloudPresenter.confirmCreate($0, in: self?.windows.active?.window, asks: self?.windows.active?.state.sidebarHidden == false ? self?.machineAsks : nil, chatOpen: { [weak self] in self?.agentTabs.tab(showing: $0) != nil }, stopAsking: self?.settings?.stopAskingCloudAgents) }
        cloud.agentsAskFirst = { [weak self] in self?.settings.map { !$0.cloudAgentsSkipAsking } ?? false }
        // The cap card's Upgrade takes the one paid-plan path (PaidPlanUpgrade): Checkout that returns here, else pricing.
        cloud.chooseAtCap = { [weak self] in await CloudMachineCapCard.choose($0, in: self?.windows.active?.window, freePlanDetail: CloudStrings.upgradeDetail(.freePlan), openPricing: { [weak self] in Task { await self?.paidPlanUpgrade().start(source: .cloudCreate) } }) }
        cloud.madeRoom = { [weak self] in if let self { CloudMove.toast(self, "cloud-made-room", CloudMachineCapCard.madeRoom($0), duration: .seconds(6)) } }
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
        // A sign-out starts: the GitHub App lease goes (its install revoke may fail), and the person's own sign-out forgets the paired phones.
        cloud.willSignOut.append { [weak self] in self?.githubAppLease.signOutStarted(); self?.iphone.signOutStarted() }
        let cloud = cloud, machines = machines
        return Task { [weak self] in
            var account: (user: String, team: String)?
            var routerUser: String??
            var leaseAccount = GitHubAppLease.Account()
            for await state in ObservationStream({ (cloud.isSignedIn, machines.cloud.count, cloud.auth.user?.id, cloud.auth.teamID, cloud.auth.managedTeamID != nil) }) {
                guard let self else { return }
                self.cloudContextDidChange()
                self.agentTabs.syncCloudCredentialTransferAvailability(services: self)
                // The local model relay follows the signed-in user (ModelRouterLease).
                let user = state.0 ? state.2 : nil
                if routerUser != .some(user) {
                    routerUser = .some(user)
                    self.modelRouter?.accountChanged(user)
                }
                // The sign-in acpmux mints GitHub App tokens with (GitHubAppLease) follows the user
                // and the active team (its cmux id), whose GitHub connection Cloud mints from.
                let team = GitHubAppLease.backendTeam(stackProjectID: cloud.auth.configuration.stackProjectID,
                                                      userID: user, stackTeamID: state.3, managed: state.4)
                if leaseAccount.changed(user: user, team: team) {
                    let project = cloud.auth.configuration.stackProjectID
                    self.githubAppLease.accountChanged(user: user.map { CloudIdentity.workerUserID(stackProjectID: project, stackUserID: $0) },
                                                       team: team)
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

extension AppServices {
    /// What hostd's `surface` service streams: phone tabs `s<surface>` as streamed simulators
    /// (``SimulatorSurfaceSources``, when SimulatorKit loads) and the owner's Cloud desktops
    /// `c~<machine>~<team>`, view only (``CloudDesktopSurfaceSources``), on any Mac.
    func phoneSurfaceHosts() -> any MobileHostSurfaceHosting {
        let phoneTabs = SimulatorSurfaceSources.available(phones) ? SimulatorSurfaceSources(phones: phones) { [weak self] raw in
            guard let self, let tab = self.daemon.store.tab(surface: SurfaceID(rawValue: raw)),
                  tab.page == InternalPageID.phone.rawValue else { return nil }
            let route = self.pages.storeKey(of: tab.id).flatMap { (self.pages.provider(.phone) as? PhonePageTab)?.route(for: $0) }
            return .some((route ?? tab.pageRoute).flatMap { PhoneDeviceID($0) })
        } : nil
        // No Cloud desktop for the phone until it has a carrier route of its own (phoneCloudLinks says so).
        return MobileHostSurfaceClosures(start: { tab, onExit in
            guard let phoneTabs else { throw SimulatorSurfaceSources.Failure.notPhoneTab }
            return try await phoneTabs.start(tab: tab, onExit: onExit)
        }, stop: { tab in await phoneTabs?.stop(tab: tab) }, stopAll: { await phoneTabs?.stopAll() }, streamsSimulators: phoneTabs != nil)
    }

    /// Forward the account's app-link Cloud machines to Rust hostd (asleep ones with no socket),
    /// and whether the plan pays for Cloud. Classic links never enter this directory.
    func phoneCloudLinks() async -> MobileHostCloudLinks {
        guard cloud.auth.isSignedIn, let user = cloud.auth.user?.id else { return MobileHostCloudLinks() }
        let selectedTeam = cloud.auth.teamID
        // The backend team in attention events is the install token claim, not a Stack team id.
        guard let token = try? await cloud.installIdentity.installToken(),
              let team = MacInstallIdentity.team(ofToken: token) else { return MobileHostCloudLinks() }
        var result: [MobileHostCloudLink] = []
        for session in machines.cloud {
            guard let link = session.appLink, !session.machine.isGoneForPhones else { continue }
            let socket = await link.currentLinkSocket
            guard machines.session(session.machineID) === session, !session.machine.isGoneForPhones else { continue }
            result.append(MobileHostCloudLink(machine: session.machine, machineID: session.machineID, teamID: team, socket: socket, cachedOwner: link.ownership.callerOwnsVM, user: cloud.auth.platformUserID ?? user))
        }
        // An account transition during either actor hop invalidates the whole answer.
        guard cloud.auth.isSignedIn, cloud.auth.user?.id == user, cloud.auth.teamID == selectedTeam else { return MobileHostCloudLinks() }
        // No desktops: a phone has no carrier route to a Cloud desktop yet, whatever `phone.cloudDesktop` says.
        return MobileHostCloudLinks(paid: machines.cloudLimits?.paysForCloud ?? false, desktops: false, links: result)
    }
}

// The profile's Computer tab's control source (Chief computer take-over): who drives the Chief's
// computer and the person's Take Over / Give Back. The view never talks to a transport itself.
extension AppServices {
    /// `agent` (a Cloud Chief's `agent_…` id): its own sandbox, whose lease the Worker owns. Else
    /// `machine` (a Cloud machine id attached to a Chief on this Mac): its lease in the app's
    /// ``ChiefComputerControlStore``, driven through Open Desktop. Nil when neither names one.
    @MainActor
    func chiefComputerControlSource(agent: String?, machine: String?) -> HomeChiefComputerControlSource? {
        if let agent, ChiefComputerControlClient.isAgentID(agent) {
            return .sandbox(agent: agent, store: cloud.computerControl, client: ChiefComputerControlClient(send: home.hostedChief.brainRoute))
        }
        guard let machine, let id = ChiefComputerControlStore.machineKey(machine) else { return nil }
        return .machine(id, store: cloud.computerControl, openInteractive: { [weak self] in self?.openChiefComputerDesktop(machine: machine) })
    }

    /// Open Desktop (`cloudOpenDesktop`) as the person's own run: the machine's `cmux-rd` desktop over the
    /// carrier, the one viewer Open Desktop has (CloudHandlers.openDesktop).
    @MainActor
    func openChiefComputerDesktop(machine: String) {
        _ = registry.perform("cloudOpenDesktop", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .machine, id: machine), arguments: [:], origin: .user))
    }
}
