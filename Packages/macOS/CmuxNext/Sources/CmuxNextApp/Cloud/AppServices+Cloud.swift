import AppKit
import CmuxNextAccounts
import CmuxNextActions
import CmuxNextAgentCursor
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextMacScreen
import CmuxNextPhone
import CmuxNextMobile
import CmuxNextMobileHost
import CmuxNextRemoteLocalhost
import CmuxNextRemoteLocalhostService
public import CmuxNextRemoteView
import CmuxNextRemoteViewSessions
import CmuxNextSettings
import Foundation
import QuartzCore

extension AppServices {
    /// Open Desktop's `cmux-rd` viewer: the machine's desktop host over the carrier, a new
    /// `cmux carrier dial --service desktop` per session with the platform origin and the person's
    /// access token (``CloudCarrierDial/Connector``, ended with the account); each session's transport in the mode it asks for.
    func cloudDesktopRdTransport(machine: String) -> (@MainActor (_ control: Bool) -> RemoteRdStreamTransport?)? {
        guard cloud.auth.isSignedIn, !cloud.policyDisabled, let session = machines.cloud.first(where: { $0.machineID.lowercased() == machine.lowercased() }),
              let dial = CloudCarrierDial.Connector(machine: session.machineID, service: .desktop, cli: cloud.binary, auth: cloud.auth, platform: cloud.configuration.relayAPIBaseURL(),
                                                    team: session.machine.team, stateDirectory: cloud.tuiState, streams: cloud.desktopStreams) else { return nil }
        return { [weak self] control in
            let carrier = RemoteRdStreamCarrier(reportingOpen: { progress in
                let stream = try await dial.open(progress: progress)
                return RemoteRdByteStream(read: { await stream.read() }, write: { try await stream.send($0) }, close: { stream.close() })
            })
            return RemoteRdStreamTransport(carrier: carrier, hello: RemoteRdHello.cloudDesktop(sharpText: self?.settings?.snapshot.remoteDesktop.sharpLinuxText ?? false), startKey: UUID().uuidString, control: control)
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
        cloud.agentCreatePolicy = { [weak self] in self?.settings.map { CloudMachineCreatePolicy(asksFirst: !$0.cloudAgentsSkipAsking, pauseAgentMachines: $0.snapshot.pauseAgentMachines) } ?? CloudMachineCreatePolicy() }
        // The cap card's Upgrade takes the one paid-plan path (PaidPlanUpgrade): Checkout that returns here, else pricing.
        cloud.chooseAtCap = { [weak self] in await CloudMachineCapCard.choose($0, in: self?.windows.active?.window, freePlanDetail: CloudStrings.upgradeDetail(.freePlan), openPricing: { [weak self] in Task { await self?.paidPlanUpgrade().start(source: .cloudCreate) } }) }
        cloud.madeRoom = { [weak self] in if let self { CloudMove.toast(self, "cloud-made-room", CloudMachineCapCard.madeRoom($0), duration: .seconds(6)) } }
        cloud.planObserved = { [weak self] in self?.paidPlanObserved($0) }
        cloud.start()
        iphone.pairedQuitRecord = agentPaneStateLoss
        iphone.wire(auth: cloud.auth, daemon: daemon, acpmuxHost: { [weak self] in self?.agentTabs.host }, acpmuxEnvironment: QuitAgents.environment(self),
                    agentTabHost: { [weak self] in self?.agentTabs.localHost },
                    newChatPicks: { [weak self] in NewChatPicks(lastAgent: self?.newTabChoices.agent, picks: self?.newTabChoices.picks) },
                    chief: { [weak self] in if let owner = self?.home.chief { IPhoneHostService.ChiefPlacement(session: owner.home.session, socket: await owner.socketPath()) } else { nil } },
                    surfaceHosts: phoneSurfaceHosts(),
                    cloudLinks: MobileCloudLinksReader(auth: cloud.auth, identity: cloud.installIdentity,
                        sessions: { [weak self] in self?.machines.cloud ?? [] },
                        machine: { ($0.machineID, $0.machine) }, link: { $0.appLink },
                        current: { [weak self] in self?.machines.session($0.machineID) === $0 },
                        paid: { [weak self] in self?.machines.cloudLimits?.paysForCloud ?? false }).read,
                    siteData: { @MainActor [weak self] request in
                        guard let self else { throw CancellationError() }
                        return try await MobileSiteDataExporter(model: self.locateTab(surface: SurfaceID(rawValue: request.surface)),
                            currentModel: { self.locateTab(surface: SurfaceID(rawValue: request.surface)) },
                            page: { self.cache.existingBrowser($0.id)?.tab }, identity: { $0 },
                            snapshot: { model, page in .init(profileID: BrowserProfileRecord.wireID(for: page.profileID),
                                incognito: self.cache.browserTabs.isIncognitoTab(model.id) || self.cache.cef.stores.offTheRecord.isOffTheRecord(page.profileID),
                                agentsProfile: BrowserProfileRecord.wireID(for: page.profileID) == AgentBrowserProfile.id,
                                url: page.state.url?.absoluteString, navigation: page.state.activeNavigation?.rawValue, isLoading: page.state.isLoading) },
                            readCookies: { try await $0.cookies() },
                            evaluate: { try await $0.evaluate($1, world: $2, gesture: $3) }).read(request)
                    },
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
            var leaseAccount = GitHubAppLease.Account()
            for await state in ObservationStream({ (cloud.isSignedIn, machines.cloud.count, cloud.auth.user?.id, cloud.auth.teamID, cloud.auth.managedTeamID != nil) }) {
                guard let self else { return }
                self.cloudContextDidChange()
                self.agentTabs.syncCloudAccountActions(services: self)
                let user = state.0 ? state.2 : nil
                // The sign-in acpmux mints GitHub App tokens with (GitHubAppLease) follows the user
                // and the active team (its cmux id), whose GitHub connection Cloud mints from.
                let team = GitHubAppLease.backendTeam(stackProjectID: cloud.auth.configuration.stackProjectID,
                                                      userID: user, stackTeamID: state.3, managed: state.4)
                if leaseAccount.changed(user: user, team: team) {
                    let project = cloud.auth.configuration.stackProjectID
                    self.githubAppLease.accountChanged(user: user.map { CloudIdentity.workerUserID(stackProjectID: project, stackUserID: $0) },
                                                       team: team)
                }
                // A switch of the active team reloads the team's machines and accounts.
                let current = state.0 ? state.2.flatMap { user in state.3.map { (user: user, team: $0) } } : nil
                guard current?.user != account?.user || current?.team != account?.team else { continue }
                // task-owner: one machine-list reload; CloudService reconciles.
                if let before = account, before.user == current?.user { Task { await cloud.refresh() }; self.accounts.model.refresh() }
                account = current
            }
        }
    }
}

extension AppServices {
    /// What hostd's `surface` service streams: phone tabs `s<surface>` as streamed simulators (``SimulatorSurfaceSources``,
    /// when SimulatorKit loads), the owner's Cloud desktops `c~<machine>~<team>` (``CloudDesktopSurfaceSources``), and
    /// this Mac's displays `d~<display>` while Share This Mac is on (``MacDisplaySurfaceSources``), these two view only.
    func phoneSurfaceHosts() -> any MobileHostSurfaceHosting {
        let phoneTabs = SimulatorSurfaceSources.available(phones) ? SimulatorSurfaceSources(phones: phones) { [weak self] raw in
            guard let self, let tab = self.daemon.store.tab(surface: SurfaceID(rawValue: raw)),
                  tab.page == InternalPageID.phone.rawValue else { return nil }
            let route = self.pages.storeKey(of: tab.id).flatMap { (self.pages.provider(.phone) as? PhonePageTab)?.route(for: $0) }
            return .some((route ?? tab.pageRoute).flatMap { PhoneDeviceID($0) })
        } : nil
        // No Cloud desktop for the phone until it has a carrier route of its own (the Cloud directory reader says so).
        let sources = PhoneSurfaceSources(phoneTabs: phoneTabs, macDisplays: MacDisplayCapture.surfaceSources { [weak self] in self?.macScreenPages.hubHost.isSharing ?? false })
        return MobileHostSurfaceClosures(start: { try await sources.start(tab: $0, onExit: $1) }, stop: { await sources.stop(tab: $0) },
                                         stopAll: { await sources.stopAll() }, streamsSimulators: phoneTabs != nil, streamsMacDisplays: true)
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
        return .machine(id, store: cloud.computerControl, openInteractive: { [weak self] in self?.openChiefComputerDesktop(machine: machine) }, send: { [weak self] input in
            guard let self, let command = HomeChiefComputerRoute.machineInputCommand(input) else { return }
            let ran = try await cloud.machineAPI.exec(machine, command: command, timeoutMs: 20_000)
            guard ran.exitCode == 0 else { throw ActionFailure(message: ran.stderr) }
        })
    }

    /// What a Cloud machine's desktop viewer calls on the person's input: it keeps their hold on its computer.
    @MainActor
    func chiefComputerInputReporter(machine: String?) -> (@MainActor () -> Void)? {
        guard let note = chiefComputerControlSource(agent: nil, machine: machine)?.noteInput else { return nil }
        return { note() }
    }

    /// Open Desktop (`cloudOpenDesktop`) as the person's own run: the machine's `cmux-rd` desktop over the
    /// carrier, the one viewer Open Desktop has (CloudHandlers.openDesktop).
    @MainActor
    func openChiefComputerDesktop(machine: String) {
        _ = registry.perform("cloudOpenDesktop", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .machine, id: machine), arguments: [:], origin: .user))
    }

    /// The loaded Cloud machines, by id, for the Chief's computer.
    @MainActor
    var cloudMachineRecords: [(id: String, machine: CloudMachine)] {
        machines.cloud.map { ($0.machineID, $0.machine) }
    }

    /// The Chief's computer's live view: `machine`'s desktop stream, watching only; nil when it serves none.
    @MainActor
    func chiefComputerLiveFeed(machine: String, name: String, agentActs: @escaping () -> Bool) -> (any HomeChiefComputerLiveFeed)? {
        guard machines.session(machine)?.machine.opensCarrierDesktop == true else {
            RemoteDesktopWatchFeed.logger.error("computer live: machine serves no carrier desktop")
            return nil
        }
        guard let transport = cloudDesktopRdTransport(machine: machine)?(false) else {
            RemoteDesktopWatchFeed.logger.error("computer live: no transport")
            return nil
        }
        return RemoteDesktopWatchFeed(name: name, transport: transport, agentActs: agentActs)
    }

    /// Draws the branded agent cursor over a Chief's screen: a Linux screen capture does not include it.
    @MainActor
    func chiefComputerPointerPainter(chief: @escaping () -> String) -> (CALayer) -> (CGPoint?) -> Void {
        { layer in
            let session = "chief-computer"
            let host = AgentCursorLayerHost(hostLayer: layer, color: AgentCursorStack.sessionColor, label: { _ in chief() })
            return { point in
                guard let point else { return host.apply(.remove(session: session)) }
                host.apply(.confine(session: session, bounds: layer.bounds))
                host.apply(.place(session: session, point: point))
            }
        }
    }
}

extension RemoteDesktopWatchFeed: HomeChiefComputerLiveFeed {}

extension AppServices {
    typealias ModelSignInOpened = @MainActor (String, @escaping @MainActor () -> Void) -> Void

    func settingsClaudeLogin(beside anchor: @escaping @MainActor () -> NSView?,
                             onOpened: @escaping ModelSignInOpened) -> SettingsCloudClaudeLogin {
        let host = SettingsCloudClaudeLoginHost(
            account: { [weak self] in
                guard let cloud = self?.cloud, cloud.auth.isSignedIn, !cloud.isSigningOut else { return nil }
                return cloud.account
            },
            caller: { [weak self] in self?.cloud.auth.platformUserID },
            personal: { [weak self] in self?.accounts.agentKeys.isPersonal == true },
            hasLoadedMachines: { [weak self] in self?.cloud.hasLoadedCurrentMachines == true },
            machineIDs: { [weak self] in self?.cloud.listedMachineIDs ?? [] },
            machine: { [weak self] id in
                guard let self, let session = machines.session(id) else { return nil }
                return settingsClaudeLink(session, beside: anchor, onOpened: onOpened)
            },
            refreshMachines: { [weak self] in await self?.cloud.refresh() ?? false },
            createMachine: { [weak self] environment, name, check in
                guard let self else { throw CancellationError() }
                return try await createSettingsClaudeMachine(beside: anchor, environment: environment, name: name, checking: check, onOpened: onOpened)
            })
        return SettingsCloudClaudeLogin(host: host)
    }

    private func settingsClaudeLink(_ session: CloudMachineSession, beside anchor: @escaping @MainActor () -> NSView?,
                                    onOpened: @escaping ModelSignInOpened) -> SettingsCloudClaudeMachineLink {
        let daemon = session.daemon
        let capability = DaemonCapability.agentSessionLoginSettings.rawValue
        let supportsLogin: @MainActor @Sendable () -> Bool = { daemon.liveIdentity?.supports(capability) == true }
        return SettingsCloudClaudeMachineLink(
            candidate: .init(record: session.machine, status: session.effectiveStatus,
                             linked: daemon.liveIdentity != nil, supportsLogin: supportsLogin()),
            ownerLink: CloudMachineLinks(appLink: session.appLink).ownerLink,
            endpoint: AgentTabRemoteHost.endpoint(on: daemon), linkHeld: { session.linkHeld() }, supportsLogin: supportsLogin,
            connect: { [weak self] check in
                guard let self else { throw CancellationError() }
                try await CloudStartSession(services: self).connected(session, byPerson: true, checking: check,
                                                                         failure: SettingsCloudClaudeLogin.startFailure)
            },
            openCallback: { [weak self] url, owner, scope in
                await self?.chatSignIn.openSettings(url, daemon: daemon, from: anchor().flatMap { self?.linkOpener.source(containing: $0) },
                                                    callbackPort: AgentPaneSignInPage.callbackPort(url), owner: owner, checking: scope, onOpened: onOpened) == true
            }
        )
    }

    private func createSettingsClaudeMachine(beside anchor: @escaping @MainActor () -> NSView?, environment: String?, name: String?,
                                            checking check: @MainActor () throws -> Void,
                                            onOpened: @escaping ModelSignInOpened) async throws -> SettingsCloudClaudeMachineLink? {
        do {
            var request = CloudMachineRequest()
            request.environment = environment
            let session = try await cloud.createMachine(name: name, startedByPerson: true, ownCreate: true, request: request, proceed: check)
            return settingsClaudeLink(session, beside: anchor, onOpened: onOpened)
        } catch CloudMachineCreateFlow.Failure.declined, CloudMachineCreateFlow.Failure.upgradeRequired(_), is CloudMachineCap.RunHere {
            return nil
        } catch let error where CloudMachineCap.refusal(error) != nil {
            return nil
        } catch {
            guard let refusal = CloudMachineCreation.proRefusal(error),
                  let window = anchor()?.window ?? windows.active?.window else { throw error }
            try check()
            let spec = CloudPresenter.planOfferSpec(refusal.message, plan: refusal.plan)
            let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
            try check()
            if answer.button == "confirm" {
                _ = await paidPlanUpgrade().start(plan: refusal.plan, source: .cloudRefusal, fallback: refusal.upgradeURL)
            }
            return nil
        }
    }
}
