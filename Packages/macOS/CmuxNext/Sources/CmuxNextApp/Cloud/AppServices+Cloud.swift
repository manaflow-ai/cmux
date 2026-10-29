import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextFeatures
import CmuxNextHomeEngine
import CmuxNextLaunch
import CmuxNextPhone
import CmuxNextMobile
import CmuxNextMobileHost
import CmuxNextPhoneAccess
import CmuxNextSettings
import CmuxNextWakeups
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
        let signedIn = cloudAuth.isSignedIn  // the auth, not `cloud`: a window's first show must not build CloudService
        context.remove([.signedIn, .signedOut, .cloudWorkspace])
        context.insert(signedIn ? .signedIn : .signedOut)
        if signedIn, let machine = windows.active?.state.machineID, machines.session(machine) != nil {
            context.insert(.cloudWorkspace)
        }
        #if DEBUG
        // `debug.cloud_machine_fixture`: a capture's Cloud machine header, with no session or sign-in.
        if DebugCloudMachineFixture.holdsCloudWorkspace(self) { context.insert(.cloudWorkspace) }
        #endif
        if registry.context != context { registry.context = context }
    }

    /// Cloud machines and the Cloud API, built at the first read (``cloudIfBuilt`` stays nil until then),
    /// with the administrator's policy and the machine create confirmation already in place.
    var cloud: CloudService {
        if let cloudIfBuilt { return cloudIfBuilt }
        let cloud = CloudService(machines: machines, auth: cloudAuth, mainWork: mainWork, work: work, deadlines: mainDeadlines,
                                 appEvents: appEvents, workspaceEvents: workspaceEvents, deviceID: environment.cloudDeviceID)
        cloudIfBuilt = cloud
        cloud.applyPolicy(disabled: cloudPolicyDisabled)
        // An agent's request waits in the sidebar card; with the active window's sidebar hidden it takes the sheet, so it never waits unseen.
        // The plan gate's Upgrade takes the one paid-plan path (PaidPlanUpgrade): Checkout that returns here, else pricing.
        cloud.confirmCreate = { [weak self] in await CloudPresenter.confirmCreate($0, in: self?.windows.active?.window, asks: self?.windows.active?.state.sidebarHidden == false ? self?.machineAsks : nil, chatOpen: { [weak self] in self?.agentTabs.tab(showing: $0) != nil },
                                                                           openPricing: { [weak self] _ in Task { await self?.paidPlanUpgrade().start(source: .cloudCreate) } }) }
        cloud.planObserved = { [weak self] in self?.paidPlanObserved($0) }
        return cloud
    }

    /// The feed mirror (`FeedDO`), started once the cmux account is signed in; built at the first read
    /// (``feedIfBuilt`` stays nil until then) with the `feed.github` setting already applied.
    var feed: FeedService {
        if let feedIfBuilt { return feedIfBuilt }
        let feed = FeedService(auth: cloudAuth, deadlines: mainDeadlines, work: work, appEvents: appEvents, workspaceEvents: workspaceEvents, energy: mainWork.energy, pausesHiddenPoll: features.isEnabled(.hiddenPollPause), bundleID: environment.launch.bundleID, showcase: environment.showcase, acpmuxEnvironment: QuitAgents.environment(self))
        feedIfBuilt = feed
        if let feedGitHub { feed.configureGitHub(enabled: feedGitHub.enabled, pollIntervalSeconds: feedGitHub.pollIntervalSeconds) }
        return feed
    }

    /// The administrator turned Cloud off or on (`FeaturePolicyEnforcer`): kept for ``cloud``'s build, applied now if built.
    func applyCloudPolicy(disabled: Bool) {
        cloudPolicyDisabled = disabled
        cloudIfBuilt?.applyPolicy(disabled: disabled)
    }

    /// The `feed.github` setting: kept for ``feed``'s build, applied now if built (a setting builds no feed).
    func configureFeedGitHub(enabled: Bool, pollIntervalSeconds: Double) {
        feedGitHub = (enabled, pollIntervalSeconds)
        feedIfBuilt?.configureGitHub(enabled: enabled, pollIntervalSeconds: pollIntervalSeconds)
    }

    /// The launch's Cloud start (`CloudStartPost`): after startup, or right after the first frame on a visible
    /// need (``cloudNeeded()``). A sign-in, a Cloud action and a `cloud.machines` read start Cloud at once.
    func postCloudStart(on startup: StartupScheduler) {
        let post = CloudStartPost(startup: startup, start: { [weak self] in self?.startCloudNow() })
        cloudStart = post
        cloudAuth.onSignIn = { [weak self] in self?.startCloudNow() }
        registry.willRunObservers.append { [weak self] id, _ in
            guard let self, cloudContext == nil, registry.descriptor(for: id)?.category == .cloud else { return }
            startCloudNow()
        }
        post.post()
    }

    /// A window shows, or waits off screen for, a Cloud machine's workspace (`WindowManager.makeController`):
    /// Cloud starts right after the first frame, or in the next frame once it passed. Nothing in tests.
    func cloudNeeded() {
        guard cloudContext == nil else { return }
        cloudStart?.need()
    }

    /// Starts Cloud once (the launch's post, or an earlier need such as a sign-in callback): restores the
    /// session, builds the feed (its mirror follows the account), follows the host replica and the hands'
    /// approval banners, re-reads Home's cloud Chiefs, and keeps the registry context current. A second
    /// call does nothing.
    func startCloudNow() {
        guard cloudContext == nil else { return }
        followCloudContext()  // first: it marks Cloud started; its body runs on a later turn, after the wiring below
        notifications.startFeedHandoff(self)  // builds the feed: its account follow waits for the restore
        notifications.followHandApprovals(cloud.hands)
        if let settings { followHostReplica(settings) }
        cloud.start()
        // A pane may outlive the Cloud teardown. Clear the agent tabs' credential recovery as soon as sign-out
        // begins so an already-open page cannot call a recovery action that native recovery rejects.
        cloud.willSignOut.append { [weak self] in self?.madeAgentTabs?.cloudCredentialTransfer = nil }
        // Each Cloud machine follows the app's cmux-tui build by itself, also while an agent works there.
        CloudMachineUpdates.start(self)
        iphone.wire(auth: cloud.auth, daemon: daemon, acpmuxHost: { [weak self] in self?.agentTabs.host }, acpmuxEnvironment: QuitAgents.environment(self),
                    agentTabHost: { [weak self] in self?.agentTabs.localHost },
                    newChatPicks: { [weak self] in NewChatPicks(lastAgent: self?.newTabChoices.agent, picks: self?.newTabChoices.picks) },
                    chief: { [weak self] in if let owner = self?.home.chief { IPhoneHostService.ChiefPlacement(session: owner.home.session, socket: await owner.socketPath()) } else { nil } },
                    surfaceHosts: phoneSurfaceHosts(),
                    settings: { [weak self] in self?.settings }, deadlines: mainDeadlines, appEvents: appEvents,
                    bundleID: environment.launch.bundleID, computerName: { await MacName().computerName() })
        iphone.pairWindow = { [weak self] in self?.windows.active?.window }
        iphone.pairNotices = IPhonePairNotices(post: { [weak self] in self?.notifications.desktop.post(id: IPhonePairNotices.id, title: $0,
            body: $1, surface: nil, workspace: nil, defaultSound: true, category: IPhonePairNotices.category) },
            withdraw: { [weak self] in self?.notifications.desktop.withdraw([IPhonePairNotices.id]) })
        home.cloudDidStart()
    }

    /// The registry context, the model router, phone access and team reloads follow the account (``cloudContext``):
    /// a ``ServiceObservation`` in the background class (its apply writes the registry, the router and phone access,
    /// which must follow while no window shows). Setting ``cloudContext`` marks Cloud started before the wiring in
    /// ``startCloudNow()``, so the first apply is one posted task after that wiring, as before.
    private func followCloudContext() {
        let cloud = cloud, machines = machines
        var account: (user: String, team: String)?
        var routerUser: String??
        let facts: @MainActor () -> CloudContextFacts = {
            (signedIn: cloud.isSignedIn, machines: machines.cloud.count, user: cloud.auth.user?.id, team: cloud.auth.teamID)
        }
        let follow: @MainActor (CloudContextFacts) -> Void = { [weak self] state in
            guard let self, let context = cloudContext, !context.isCancelled else { return }
            cloudContextDidChange()
            madeAgentTabs?.syncCloudCredentialTransferAvailability(services: self)  // agent tabs made later sync when built
            // The local model relay follows the signed-in user (ModelRouterLease).
            let user = state.signedIn ? state.user : nil
            if routerUser != .some(user) {
                routerUser = .some(user)
                modelRouter?.accountChanged(user)
            }
            // Phone access follows the account: start after sign-in, restart on a user or team switch,
            // stop on sign-out. A switch of the active team also reloads the team's machines and accounts.
            let current = state.signedIn ? state.user.flatMap { user in state.team.map { (user: user, team: $0) } } : nil
            guard current?.user != account?.user || current?.team != account?.team else { return }
            if let before = account, before.user == current?.user {
                cloud.refreshOffMain()  // CloudService reconciles
                accounts.model.refresh()
            }
            account = current
            if let auth = CloudMobileAuth(auth: cloud.auth, mainWork: mainWork) {
                mobile.start(auth: auth, launch: environment.launch, daemon: daemon)
            } else {
                mobile.stop()
            }
        }
        // The init's own apply finds no `cloudContext` yet and does nothing.
        cloudContext = ServiceObservation(.background, owner: "AppServices.cloudContext", on: mainWork, read: facts, apply: follow)
        mainWork.post(.background, owner: "AppServices.cloudContext") { follow(facts()) }
    }

    /// The phone host replica follows `settings` and the signed-in account (from the Cloud start on).
    func followHostReplica(_ settings: SettingsController) {
        cloud.hostReplica.follow(settings, local: machines.local, on: mainWork, account: { [cloud] in cloud.auth.isSignedIn && cloud.mayCallCloud && !cloud.policyDisabled ? cloud.auth.user?.id : nil })
    }

    /// At quit: ends the Cloud start's follow, Cloud and its machines' connections. Builds nothing when Cloud never started.
    func stopCloud() {
        guard let cloudContext else { return }
        cloudContext.cancel()
        cloud.stop()
        for session in machines.cloud { session.disconnect() }
    }
}

extension AppServices {
    /// The phone tabs of this app's daemon as streamed simulators (``SimulatorSurfaceSources``); nil when none can stream.
    func phoneSurfaceHosts() -> (any MobileHostSurfaceHosting)? {
        guard SimulatorSurfaceSources.available(phones) else { return nil }
        let sources = SimulatorSurfaceSources(phones: phones) { [weak self] raw in
            guard let self, let tab = self.daemon.store.tab(surface: SurfaceID(rawValue: raw)),
                  tab.page == InternalPageID.phone.rawValue else { return nil }
            let route = self.pages.storeKey(of: tab.id).flatMap { (self.pages.provider(.phone) as? PhonePageTab)?.route(for: $0) }
            return .some((route ?? tab.pageRoute).flatMap { PhoneDeviceID($0) })
        }
        return MobileHostSurfaceClosures(start: { tab, onExit in try await sources.start(tab: tab, onExit: onExit) },
                                         stop: { tab in await sources.stop(tab: tab) }, stopAll: { await sources.stopAll() })
    }
}
