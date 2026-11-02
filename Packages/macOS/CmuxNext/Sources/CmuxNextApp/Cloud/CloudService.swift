import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextPhoneAccess
import CmuxNextRemoteLocalhost
import Foundation
import Observation
import os
import CmuxNextWakeups

/// Cloud orchestration: sign-in state, the machine list from `/api/vm`, and
/// one `CloudMachineSession` per live machine in `MachineRegistry`. The
/// list is fetched when the session restores or signs in, after every
/// machine mutation, and when the app becomes active (at most every 30 s);
/// there is no polling timer.
@Observable
final class CloudService {
    let configuration: CloudConfiguration
    let auth: CloudAuth
    @ObservationIgnored let api: CloudAPIClient
    /// A machine's exec and file routes: ``api`` on the legacy link, the cmux API Worker's on the
    /// app server link, whose machines have no `/api/vm` row (cmux-platform#89).
    @ObservationIgnored let machineAPI: CloudAPIClient
    /// Same person and team as the machine API, at the configured platform preview origin.
    var previewAPI: CloudAPIClient? {
        configuration.platformPreviewAPIBaseURL().map { machineAPI.previewClient(baseURL: $0) }
    }
    /// The machines a `cloud deliver-secrets` runs for now: one delivery per machine at a time.
    @ObservationIgnored var deliveringSecrets: Set<String> = []
    @ObservationIgnored let networkAccess = CloudNetworkAccessQueue() // one network policy read-then-write per machine
    @ObservationIgnored let paths: CloudPaths
    /// One app-lifetime owner of confirmed, per-account Codex delivery.
    let codexBroker: CloudCodexBrokerAdapter
    @ObservationIgnored private let work: BackgroundWork
    @ObservationIgnored private(set) var hub: CloudTunnelHub?
    /// Whether a cmux Pro offer is on screen (CloudPresenter.offerPro).
    @ObservationIgnored var proOfferOpen = false
    /// Each machine list that carries the plan (`limits.planId`) reports it: the paid-plan welcome step
    /// (AppServices+PaidPlan.swift) watches for the plan turning paid after an upgrade.
    @ObservationIgnored var planObserved: @MainActor (String?) -> Void = { _ in }
    /// Open Desktop's `cmux-rd` viewer: each machine's desktop host session token (lowercased id),
    /// fetched over the signed-in Cloud API when a person opens it, held only in memory.
    @ObservationIgnored var desktopRdTokens: [String: String] = [:]
    /// The tunnel's SOCKS socket and client token, starting it when needed: how the browser
    /// reaches a machine's localhost over this Mac's own WireGuard tunnel (RemoteLocalhostService).
    /// Nil without the hub.
    var tunnelSocket: HubLoopbackOpener.Hub? {
        guard let hub else { return nil }
        let endpoint: HubLoopbackOpener.Hub = {
            let endpoint = try await hub.endpoint()
            return HubLoopbackOpener.Endpoint(socket: endpoint.socket, token: endpoint.clientToken)
        }
        return endpoint
    }
    /// This Mac's Cloud install principal (cx-wb5.64): install tokens for the
    /// credential relay; registered at sign-in, revoked at sign-out.
    @ObservationIgnored let installIdentity: MacInstallIdentity
    /// The install guest links' owner tokens come from (``CloudConfiguration/shareAPIBaseURL(environment:)``):
    /// ``installIdentity`` when both name one API, else a second install there, registered at the first share
    /// (``shareOwnerToken()``) and revoked with it.
    @ObservationIgnored let shareInstallIdentity: MacInstallIdentity
    /// `phone.cloudReplica`: this Mac's workspace list for phones while it is off.
    @ObservationIgnored let hostReplica: CloudHostReplicaFollower
    /// Chief hands: levels, the presence key and requests waiting for the owner (cx-om025).
    @ObservationIgnored let hands: HandsService
    @ObservationIgnored private let machines: MachineRegistry
    /// The plan gate for a create, from the last machine list's limits.
    var createGate: CloudMachineCreateFlow.Gate { CloudMachineCreateFlow.gate(machines.cloudLimits) }
    /// The plan's machine sizes a person's create offers, from the last machine list: its limits'
    /// sizes and the rates the server gave listed machines of the same size. Read from the list
    /// itself, so a machine this Mac could not connect to still gives its size a rate.
    private(set) var planSizes: [CloudWorkspaceSetupWizard.SizeOption] = []
    /// The app's `cmux-tui` (the hub's, the moves' and `cloud enroll-machine`'s `wg dial`).
    @ObservationIgnored let binary: URL?
    /// This Mac's `cmux link` across the session (cx-rtipa S3).
    @ObservationIgnored private let link: CloudLinkLifecycle
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private let refreshGate = CloudRefreshGate()
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    /// The local side event subscription for `cloud.link.changed` (app link).
    @ObservationIgnored private var linkEvents: UInt64?
    /// The `credential` provider family on the local daemon (cx-wb5.63):
    /// app servers' Cloud API calls, sent with the install token.
    @ObservationIgnored private var credentialProvider: CloudCredentialProvider?
    @ObservationIgnored private var credentialEvents: UInt64?
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
    /// The last list or connection failure, for diagnostics and refusals.
    private(set) var lastError: String?
    private(set) var hasLoadedMachines = false
    /// Whom the loaded list is for (``listAccount`` when it landed).
    @ObservationIgnored private var loadedAccount: [String?]?
    /// The machines the loaded list named (and machines made since for that account): a session the
    /// store keeps while an omission waits on a newer read (``reconcile(_:read:connectsAtRead:)``)
    /// may be another team's, and is not one of them.
    private(set) var listedMachineIDs: Set<String> = []
    /// Whether the store holds a list the server answered for the user and team signed in now
    /// (``CloudMachineListFacts/hasLoadedCurrentMachines`` owns the rule and why a team switch matters).
    var hasLoadedCurrentMachines: Bool { listFacts.hasLoadedCurrentMachines }
    /// The sign-in and list state that decides whether a saved Cloud workspace is gone (`WindowManager.isDead`).
    var listFacts: CloudMachineListFacts {
        CloudMachineListFacts(isSignedIn: isSignedIn, isRestoring: auth.isRestoring, hasLoadedMachines: hasLoadedMachines,
                              loadedFor: loadedAccount, account: listAccount)
    }
    /// The Cloud app server's ops on the local daemon (contract 2.1).
    var appOps: CloudAppOp { CloudAppLinks.ops(local: machines.local) }
    /// The person's confirmation of a create (set by AppServices: a sheet in the active window, or the
    /// sidebar card for an agent's or a script's request while that sidebar shows); none answers false.
    @ObservationIgnored var confirmCreate: (@MainActor (CloudMachineCreateFlow.Prompt) async -> Bool)?
    /// Machine creations in flight (sidebar can show a placeholder).
    private(set) var creating = 0
    @ObservationIgnored let changes = CloudMachineChanges()
    /// The names app server creates in flight asked for, typed or default: a default picked meanwhile skips them.
    @ObservationIgnored private var machineNamesInFlight: [String] = []
    /// New Cloud Workspace runs from the click to the open terminal: each
    /// window's progress view and sidebar row (cx-lu8f).
    let creations = CloudCreations()
    /// Move to Cloud's CLI and machine folders.
    @ObservationIgnored var move = CloudMoveSetup()
    /// What Retry does for each chat whose move stopped.
    @ObservationIgnored let moveRetries = CloudMoveRetries(key: "cmux.cloud.moveRetries")
    /// What Retry does for each machine chat whose Bring Back Local stopped, by its tab there.
    @ObservationIgnored let bringBackRetries = CloudMoveRetries(key: "cmux.cloud.bringBackRetries")
    /// The chats moved from this Mac, for Bring Back Local.
    @ObservationIgnored let movedChats = CloudMovedChats()
    /// Agents' asks to move their chats, and the cards they raise in chats.
    @ObservationIgnored let moveAsks = CloudMoveAsks()
    @ObservationIgnored let toolCards = AgentToolCards()
    /// Agents' asks to start a session on a Cloud machine (``CloudStartSessionAsks``).
    @ObservationIgnored let startSessionAsks = CloudStartSessionAsks()
    /// `cmux cloud start-session` runs, joined by a repeat of the same ask (``CloudStartSessionRuns``).
    @ObservationIgnored let startSessionRuns = CloudStartSessionRuns()
    @ObservationIgnored let signedOutCreation = CloudSignedOutCreationContinuation()
    #if DEBUG
    /// `debug.cloud_machine_fixture {backend: true}`: Cloud reads as reachable in a capture build that has no
    /// Cloud backend or client, so its actions show the signed-out state a person's build does.
    @ObservationIgnored var debugBackendFixture = false
    #endif
    /// When the loaded list landed (``hasCurrentList(within:)``).
    @ObservationIgnored private var listLoadedAt: ContinuousClock.Instant?
    /// Moved chats' file requests for this Mac, asked in their chats.
    @ObservationIgnored let accessAsks = CloudAccessAsks()
    /// Files the person drops or pastes into a moved chat, sent to its machine (``CloudUploads``).
    @ObservationIgnored let uploads = CloudUploads()
    /// Staged uploads into ssh-peer chats, beside the Cloud ones (``AgentPeerUploads``).
    @ObservationIgnored let peerUploads = AgentPaneStagedUploads<AgentPeerUploads.Target>(owner: "AgentPeerUploads.stageExpiry")

    /// The app's main-thread scheduler, passed by the composition root: every Cloud machine's event
    /// batches run on it (one main thread, one budget).
    @ObservationIgnored private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - mainWork: The app's ``MainWorkScheduler`` (AppServices passes the one it was built with).
    ///   - work: The app's blocking-work lanes: the install id is read on its files lane (``CloudDeviceID``).
    init(machines: MachineRegistry, isDebugBuild: Bool, mainWork: MainWorkScheduler, work: BackgroundWork, loginKeychain: LoginKeychain, authCaptureFixture: Bool = false) {
        self.machines = machines
        self.mainWork = mainWork
        self.work = work
        configuration = CloudConfiguration.current(isDebugBuild: isDebugBuild)
        auth = CloudAuth(configuration: configuration, captureFixture: authCaptureFixture)
        paths = CloudPaths.standard(bundleID: configuration.bundleID)
        deviceID = CloudDeviceID(paths: paths, work: work)
        let auth = auth
        api = CloudAPIClient(
            configuration: configuration,
            tokens: { try await auth.tokens() },
            teamID: { await auth.teamID })
        let configuration = self.configuration, paths = self.paths
        let install = { (api: URL, folder: String) in
            MacInstallIdentity(
                store: .forApp(directory: paths.root.appendingPathComponent(folder, isDirectory: true),
                               service: "\(configuration.bundleID ?? "cmux").install-key.\(api.host ?? "unknown")",
                               team: CodeSigningTeam.current(), isDebugBuild: configuration.isDebugBuild, loginKeychain: loginKeychain),
                transport: InstallHTTPTransport(baseURL: api),
                deviceName: Self.deviceName,
                clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
        }
        let identity = install(configuration.ownerAPIBaseURL(), "install")
        installIdentity = identity
        let shareAPI = configuration.shareAPIBaseURL()
        shareInstallIdentity = shareAPI == configuration.ownerAPIBaseURL() ? identity : install(shareAPI, "install-share")
        machineAPI = configuration.linkSource == .appServer
            ? CloudAPIClient.workerMachines(baseURL: configuration.ownerAPIBaseURL(), accessToken: { try await auth.tokens().access },
                                            teamID: { (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) },
                                            machineIO: CloudMachineIO(bundleResources: Bundle.main.resourceURL, cloudRoot: paths.root, work: work))
            : api
        let api = api, machineAPI = machineAPI
        let build = LaunchIdentity.current().build
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        let environment = ProcessInfo.processInfo.environment
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        codexBroker = CloudCodexBrokerAdapter(root: paths.root, registry: CloudCodexBrokerRegistry(),
            currentScope: {
                guard auth.isSignedIn, let user = auth.user else { return nil }
                return CloudCodexBrokerScope(userID: user.id, teamID: auth.teamID)
            },
            launch: {
                try await work.run(.userVisible, mayBlock: .files) {
                    guard let acpmux = AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin,
                        environment: environment, userHome: userHome) else { throw CloudCodexBrokerError.brokerUnavailable }
                    let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
                        + [userHome.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
                    guard let codex = search.filter { $0.hasPrefix("/") }.map({ URL(fileURLWithPath: $0).appendingPathComponent("codex") })
                        .first(where: { FileManager.checked.isExecutableFile(atPath: $0.path) }) else {
                        throw CloudCodexBrokerError.brokerUnavailable
                    }
                    return CloudCodexBrokerAdapter.Launch(executable: acpmux.executable, prefix: [], codex: codex)
                }
            }, target: { [linkSource = configuration.linkSource, weak machines] scope, machineID in
                guard linkSource == .appServer else { return CloudCodexBrokerTarget(api: api, machineID: machineID, scope: scope) }
                // A Worker machine: its app link's own owner answer and the app's record, never /api/vm.
                return CloudCodexBrokerTarget(api: machineAPI, machineID: machineID, scope: scope, callerOwnsVM: {
                    guard let link = await MainActor.run(body: { machines?.session(machineID)?.appLink }) else { return false }
                    return await link.ownerLink != nil
                }, isLive: {
                    await MainActor.run { machines?.session(machineID)?.machine.status.isLive ?? false }
                })
            })
        hostReplica = CloudHostReplicaFollower(origin: HomeCloudLease.origin(configuration.ownerAPIBaseURL()),
            clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            installToken: { [installIdentity] in let token = try await installIdentity.installToken(); return (token, HomeCloudLease.expiry(ofJWT: token) ?? HomeCloudLease.fallbackExpiry(now: Date())) },
            invalidate: { [installIdentity] in await installIdentity.invalidate() })
        hands = HandsService(
            apiBaseURL: configuration.ownerAPIBaseURL(), accessToken: { [auth] in try await auth.tokens().access }, identity: installIdentity,
            presence: HandPresenceKeyStore(directory: paths.root.appendingPathComponent("install", isDirectory: true)))
        let relay = CloudCredentialRelay.live(identity: identity, baseURL: configuration.ownerAPIBaseURL(),
            signedIn: { [auth] in await MainActor.run { auth.isSignedIn } },
            allowedOps: { await CloudCredentialRelay.bundledServedOps() })
        credentialProvider = CloudCredentialProvider(relay: relay)
        let launcher = configuration.linkSource == .appServer
            ? CloudLinkLauncher.forApp(build: LaunchIdentity.current().build, relay: relay) : nil
        link = CloudLinkLifecycle(launcher: launcher, installID: { [identity] in await identity.installID() },
                                  connection: { [machines] in machines.local.connection })
        binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        move.cli = binary
        move.ledger = .standard
        if let binary {
            hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: Self.deviceName)
        }
        movedChats.defaults = { [weak self] in self?.move.ledger }
        moveRetries.defaults = { [weak self] in self?.move.ledger }
        bringBackRetries.defaults = { [weak self] in self?.move.ledger }
        moveAsks.defaults = { [weak self] in self?.move.ledger }
        CloudMovedChats.app = movedChats
        link.isAvailable = { [weak self] in self.map { $0.mayCallCloud && !$0.policyDisabled && $0.auth.isSignedIn } ?? false }
        link.isSignedIn = { [weak self] in self?.auth.isSignedIn ?? false }
        startSessionAsks.toolCards = toolCards
    }

    static var deviceName: String { MacName().linkDeviceName() }
    /// This Mac's install id for a synchronous caller (``CloudDeviceID/loadNow()``): read once, on the files
    /// lane when Cloud starts; async callers use ``installID()``.
    func localDeviceID() throws -> String { try deviceID.loadNow() }
    /// This Mac's install id, read off the main thread (``CloudDeviceID/load()``).
    func installID() async throws -> String { try await deviceID.load() }

    /// Whether the signed-in caller owns `machineID`, as the platform answers it and as the Codex
    /// broker's target reads it: the classic attach answer's `vmKind == "owner"` (#28788 gives a team
    /// machine's creator that), or a Worker machine's owner link on the app server link. A personal
    /// harness login goes only to such a machine (``CloudCredentialTransfer``).
    func callerOwnsVM(_ machineID: String) async throws -> Bool {
        guard configuration.linkSource == .appServer else {
            return try await api.pinningTeam(auth.teamID).attachEndpoint(machineID).vmKind == "owner"
        }
        guard let link = machines.session(machineID)?.appLink else { return false }
        return await link.ownerLink != nil
    }
    @ObservationIgnored private let deviceID: CloudDeviceID

    var isSignedIn: Bool { auth.isSignedIn }

    /// Why Cloud cannot run in this build, or nil.
    var unavailableReason: String? {
        if policyDisabled { return RefusalStrings.turnedOffByOrganization }
        // RestrictToManagedTeam (P17-3): no request goes out without the managed team.
        if auth.managedTeamID != nil, auth.teamID == nil { return RefusalStrings.turnedOffByOrganization }
        // The app server path needs no web backend (cx-t2rz): only the legacy /api/vm path does.
        #if DEBUG
        if debugBackendFixture { return nil }
        #endif
        if case .localOnly = configuration.backend, configuration.linkSource == .legacy { return CloudStrings.localBackend }
        if binary == nil { return CloudStrings.noClient }
        return nil
    }

    /// Whether a Cloud API request may go out: not turned off by the
    /// organization, the managed team present (P17-3), not a local-only
    /// backend. (A missing cmux-tui client blocks machines, not the API.)
    var mayCallCloud: Bool {
        if policyDisabled { return false }
        if auth.managedTeamID != nil, auth.teamID == nil { return false }
        if case .localOnly = configuration.backend, configuration.linkSource == .legacy { return false }
        return true
    }

    func start() {
        deviceID.preload()
        auth.start(); changes.start()
        startCredentialProvider()
        if configuration.linkSource == .appServer, linkEvents == nil {
            // `cloud.link.changed` arrives on the local daemon as an app server event.
            let machines = machines
            linkEvents = machines.local.store.sideEvents.subscribe { event in
                guard let change = CloudAppLinks.change(in: event) else { return }
                machines.session(change.key.machine)?.linkChanged(change)
            }
            // task-owner: observers; cancelled in stop()
            observers.append(Task {
                // A reconnected local connection is a new daemon client: subscribe it again.
                for await state in ObservationStream({ machines.local.store.connectionState }) {
                    guard case .connected = state, machines.cloud.contains(where: { $0.appLink != nil }) else { continue }
                    await CloudAppLinks.resubscribe(local: machines.local)
                }
            })
        }
        observers.append(Task { [weak self] in
            guard let self else { return }
            await auth.awaitRestored()
            // The account, not only signed-in: Switch Account stays signed in.
            for await account in ObservationStream({ self.auth.isSignedIn ? (self.auth.user?.id ?? "") : nil }) {
                if account != nil {
                    // Sign-out revoked the WireGuard peer and parked the hub.
                    await self.hub?.resume()
                    // Another account's machines and connections end first.
                    if await self.link.sessionBegan(user: self.auth.user?.id) { self.dropAllMachines() }
                    // The install first: the app server path's first list goes
                    // through the credential relay, which sends the install token.
                    await self.installSignedIn()
                    self.hands.start()
                    await self.ensureLink()
                    await self.refresh()
                } else {
                    self.dropAllMachines()
                    // The session ended (signed out here or elsewhere, or
                    // expired): no link keeps running for it.
                    await self.link.endLink(final: true)
                    await self.installIdentity.unbind()
                    if self.shareInstallIdentity !== self.installIdentity { await self.shareInstallIdentity.unbind() }
                    self.hands.stop()
                }
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self, let last = self.lastRefresh, last.duration(to: .now) > .seconds(30) else { continue }
                await self.refresh()
            }
        })
        // After sleep the list is stale even with cmux in front: the idle
        // auto-pause may have parked machines while the lid was closed.
        observers.append(Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                await self?.refresh(ifOlderThan: .seconds(30))
            }
        })
        // A sign-out or a team switch (the user signed in may stay) ends start-session asks and
        // runs: none goes on in the account signed in after.
        observers.append(Task { [weak self] in
            guard let self else { return }
            var last = account
            for await account in ObservationStream({ self.account }) where account != last {
                signedOutCreation.scopeDidChange(from: last, to: account)
                last = account
                await codexBroker.scopeDidChange()
                startSessionRuns.forgetAll()
                startSessionAsks.endAll()
            }
        })
    }

    /// Set while an administrator turned Cloud off (`DisabledFeatures`).
    private(set) var policyDisabled = false

    /// Turning Cloud off disconnects every machine and keeps its workspaces
    /// (their terminals show "Turned off by your organization"); the VMs
    /// keep running. Turning it on again reconnects from a fresh list.
    func applyPolicy(disabled: Bool) {
        guard disabled != policyDisabled else { return }
        policyDisabled = disabled
        // Fence Codex broker requests synchronously with the policy flip. The
        // adapter tears down holders asynchronously and retains their private
        // homes for a later confirmed run after policy is restored.
        codexBroker.setAvailable(!disabled)
        if disabled {
            changes.stop()
            signedOutCreation.cancel()
            for session in machines.cloud {
                session.daemon.policyBlock.set(true)
                session.disconnect()
            }
            // The local tunnel hub stops too; nothing is revoked remotely.
            // task-owner: one teardown hop; hub.stop() is idempotent
            if let hub { Task { await hub.stop() } }
            // So does this Mac's link (the session stays).
            link.policyTurnedOff()
        } else {
            changes.start()
            dropAllMachines()
            // task-owner: one list fetch after the policy lifted
            Task { [weak self] in
                guard let self, auth.isSignedIn else { return }
                await hub?.resume()
                await installSignedIn()
                await refresh()
            }
        }
    }

    func stop() {
        refreshGate.cancel()
        signedOutCreation.cancel()
        for observer in observers { observer.cancel() }
        observers.removeAll(); changes.stop()
        if let linkEvents { machines.local.store.sideEvents.unsubscribe(linkEvents) }
        linkEvents = nil
        if let credentialEvents { machines.local.store.sideEvents.unsubscribe(credentialEvents) }
        credentialEvents = nil
        credentialProvider?.stop()
        for session in machines.cloud { session.disconnect() }
        // task-owner: teardown hop at quit; hub.stop() is idempotent
        if let hub { Task { await hub.stop() } }
    }

    /// The quit coordinator awaits this before AppKit may terminate the
    /// process, while Cloud transports can still erase delivered access.
    func prepareForTermination() async { await codexBroker.shutdown() }

    /// Serves the `credential` family on the local daemon: answers its
    /// calls on the connection that sent them, and registers again after
    /// every handshake of the verified app connection (a reconnected
    /// connection is a new provider; its calls in flight ended with it).
    /// Only the app server path uses it: with the legacy link (the release
    /// and default Debug path) the relay never registers.
    private func startCredentialProvider() {
        guard configuration.linkSource == .appServer, let provider = credentialProvider, credentialEvents == nil else { return }
        let local = machines.local
        credentialEvents = local.store.sideEvents.subscribe { [weak local] event in
            guard let connection = local?.connection else { return }
            provider.handle(event) { result in _ = try await connection.request(result) }
        }
        // task-owner: observers; cancelled in stop()
        observers.append(Task {
            for await state in ObservationStream({ local.store.connectionState }) {
                guard case .connected = state, let connection = local.connection else { continue }
                provider.stop()
                let allowed = await connection.userOriginAllowed
                _ = await CloudCredentialProvider.register(userOriginAllowed: allowed) { try await connection.request($0) }
            }
        })
    }

    // MARK: Machine list

    /// Bumped by each ``refresh()``, by ``dropAllMachines()`` and by a create
    /// or delete here: a list that comes back after a newer refresh started,
    /// after the account's machines were dropped (sign-out, another account),
    /// or after this app added or removed a machine, is stale.
    @ObservationIgnored private var listGeneration = 0
    /// Orders every read of machine records (a list, Machine Status's one record) by when it was asked.
    @ObservationIgnored private var recordReads = 0
    /// Per machine, the read whose record it holds: an older read's answer that lands later changes nothing.
    @ObservationIgnored private var recordReadApplied: [String: Int] = [:]
    /// Only one-record reads protect their own machine from an older list's removal.
    @ObservationIgnored private(set) var recordReadsOutstanding: [Int: String] = [:]
    /// Omitted machines awaiting a newer status read; retired as soon as that read finishes.
    @ObservationIgnored private var deferredRecordRemovals: [String: Int] = [:]

    /// Fetches `/api/vm` and reconciles sessions: new live machines connect,
    /// gone machines disconnect, records update in place. A stale list (see
    /// `listGeneration`), or one fetched for another user or team than the
    /// one signed in when it lands, changes nothing: it can neither bring back
    /// a signed-out account's machines, nor undo a create or delete it did not
    /// see, nor mark the store loaded with an older answer than the latest.
    /// True only when this call's batch landed for the same account: a failed or skipped call is false,
    /// whatever the store held before it.
    @discardableResult
    func refresh() async -> Bool {
        guard auth.isSignedIn, unavailableReason == nil else { return false }
        let account = listAccount
        let refreshed = await refreshGate.run { [weak self] in
            guard let self else { return false }
            return await self.performRefresh()
        }
        return refreshed && auth.isSignedIn && unavailableReason == nil && account == listAccount && hasLoadedCurrentMachines
    }

    /// The gate starts each batch in current auth/policy state, including follow-ups.
    private func performRefresh() async -> Bool {
        guard auth.isSignedIn, unavailableReason == nil, !Task.isCancelled else { return false }
        changes.start()
        lastRefresh = .now
        listGeneration += 1
        let generation = listGeneration
        let read = beginRecordRead()
        defer { finishRecordRead(read) }
        let account = listAccount
        let connectsAtRead = Dictionary(machines.cloud.map { ($0.machineID, $0.connects) }, uniquingKeysWith: { first, _ in first })
        do {
            let list: [CloudMachine]
            let limits: CloudMachineLimits?
            if configuration.linkSource == .appServer {
                list = try await appServerMachines()
                limits = nil
            } else {
                let listed = try await api.listMachinesAndLimits()
                list = listed.machines
                limits = listed.limits
            }
            guard listGeneration == generation, auth.isSignedIn, listAccount == account, unavailableReason == nil, !Task.isCancelled else { return false }
            machines.cloudLimits = limits
            planSizes = CloudWorkspaceSetupWizard.SizeOption.options(limits: limits, machines: list)
            if let limits { planObserved(limits.planId) }
            lastError = nil
            reconcile(list, read: read, connectsAtRead: connectsAtRead)
            changes.listed(machines.cloud.map(\.machine)) { [weak self] in _ = await self?.refresh() }
            hasLoadedMachines = true
            loadedAccount = account
            listedMachineIDs = Set(list.filter { $0.status != .destroyed }.map(\.id))
            listLoadedAt = .now
            await startHubForSSHRoutes()
            return true
        } catch {
            guard listGeneration == generation, auth.isSignedIn, listAccount == account, unavailableReason == nil, !Task.isCancelled else { return false }
            lastError = CloudStrings.errorText(error)
            logger.error("machine list failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// ``refresh()`` unless the list was read within `age`; true when the store then holds a list
    /// the server answered within `age` for the account signed in now.
    @discardableResult
    func refresh(ifOlderThan age: Duration) async -> Bool {
        if let last = lastRefresh, last.duration(to: .now) < age { return hasCurrentList(within: age) }
        return await refresh()
    }

    /// Whom a machine list is for: the signed-in user and the team the API
    /// client sends (``CloudAuth/teamID``).
    private var listAccount: [String?] { [auth.user?.id, auth.teamID] }

    /// The user and team signed in now (observable: ``CloudAuth``). Start-session asks and runs
    /// belong to the one they were asked in.
    var account: [String?] { listAccount }

    /// Whether the store holds a list the server answered, within `age`, for the user and team
    /// signed in now: a failed or superseded refresh, or another team's list, is not one.
    func hasCurrentList(within age: Duration) -> Bool {
        Self.listIsCurrent(loadedAt: hasLoadedMachines ? listLoadedAt : nil, loadedFor: loadedAccount, account: listAccount, now: .now, within: age)
    }

    /// Takes a read ticket before sending. A one-record request names its machine; a list does not.
    func beginRecordRead(machineID: String? = nil) -> Int {
        recordReads += 1
        // Lists need ordering only; they must never acquire an outstanding status entry.
        if let machineID { recordReadsOutstanding[recordReads] = machineID }
        changes.readIssued(recordReads)
        return recordReads
    }

    /// Retires a completed or superseded status read; an ordering-only list ticket is a no-op.
    func finishRecordRead(_ read: Int) {
        guard recordReadsOutstanding.removeValue(forKey: read) != nil else { return }
        processDeferredRecordRemovals()
    }

    /// `connectsAtRead` fences a list against a connection begun after that list was requested.
    func reconcile(_ list: [CloudMachine], read: Int, connectsAtRead: [String: Int] = [:]) {
        // A list that arrives after Cloud was turned off connects nothing.
        guard !policyDisabled else { return }
        let visible = list.filter { $0.status != .destroyed }
        for machine in visible {
            if let session = machines.session(machine.id) {
                apply(machine, to: session, read: read, connectsAtRead: connectsAtRead[machine.id])
            } else {
                // Do not resurrect a machine removed by a newer detail/list response.
                guard read > recordReadApplied[machine.id, default: 0] else { continue }
                // The machine's record now comes from this list: older reads land behind it.
                recordReadApplied[machine.id] = read
                addSession(changes.applyingPending(to: machine, read: read))
            }
        }
        let ids = Set(visible.map(\.id))
        for session in machines.cloud where !ids.contains(session.machineID) {
            deferredRecordRemovals[session.machineID] = max(read, deferredRecordRemovals[session.machineID, default: 0])
        }
        processDeferredRecordRemovals()
    }

    private func processDeferredRecordRemovals() {
        guard !policyDisabled else { return }
        for (machineID, read) in deferredRecordRemovals {
            // A later successful read saw this machine, superseding the omission.
            if recordReadApplied[machineID, default: 0] >= read {
                deferredRecordRemovals[machineID] = nil
                continue
            }
            // A status request for another machine cannot delay this removal.
            guard !recordReadsOutstanding.contains(where: { $0.key > read && $0.value == machineID }) else { continue }
            deferredRecordRemovals[machineID] = nil
            recordReadApplied[machineID] = max(read, recordReadApplied[machineID, default: 0])
            // A list omission is not proof that the provider VM was destroyed: retired
            // provider rows can be filtered while the VM still exists. Revoke delivered
            // access, but retain the broker target/auth mode unless destruction is explicit.
            removeConfirmedMachine(machineID, destructionConfirmed: false)
        }
    }

    /// Remove the app session after an authoritative omission or destroyed detail. Only a
    /// destroyed detail may discard the broker's target/auth metadata; an omission may be a
    /// filtered retired-provider row while the VM survives.
    private func removeConfirmedMachine(_ machineID: String, destructionConfirmed: Bool) {
        deferredRecordRemovals[machineID] = nil
        guard machines.session(machineID) != nil else { return }
        changes.removed(machineID)
        if let user = auth.user {
            let scope = CloudCodexBrokerScope(userID: user.id, teamID: auth.teamID)
            // task-owner: confirmed removal stops renewal, then discards the deleted target.
            Task {
                try? await codexBroker.revoke(machineID: machineID, scope: scope)
                if destructionConfirmed {
                    await codexBroker.machineWasDeleted(machineID, scope: scope)
                }
            }
        }
        creations.machineRemoved(machineID)
        machines.remove(machineID)?.disconnect()
    }

    /// A fresh record for `session` (a list refresh, or Machine Status reading one machine): a
    /// machine that stopped being live suspends its link, and one that turned live connects.
    /// `read` (``beginRecordRead(machineID:)``): a record from a read asked before the one the session
    /// holds changes nothing, so answers that land out of order run no stale transition.
    func apply(_ machine: CloudMachine, to session: CloudMachineSession, read: Int, connectsAtRead: Int? = nil) {
        // Apply the newer record before releasing any removal it was protecting.
        defer { finishRecordRead(read) }
        guard !policyDisabled, machine.id == session.machineID,
              read > recordReadApplied[machine.id, default: 0], machines.session(machine.id) === session else { return }
        recordReadApplied[machine.id] = read
        if machine.status == .destroyed {
            session.machine = machine
            removeConfirmedMachine(machine.id, destructionConfirmed: true)
            return
        }
        // Read ordering admits the record; mutation tracking supplies presentation until the
        // matching operation settles, so an in-flight status read cannot reopen action gates.
        session.listed(changes.applyingPending(to: machine, read: read), connectsAtRead: connectsAtRead ?? session.connects)
    }

    @discardableResult
    private func addSession(_ machine: CloudMachine) -> CloudMachineSession? {
        guard !policyDisabled else { return nil }
        let session: CloudMachineSession
        switch configuration.linkSource {
        case .appServer:
            let resolver = CloudConnectOpResolver(run: CloudAppLinks.runner(local: machines.local) { [weak self] in
                await self?.ensureLink()
            })
            let local = machines.local
            session = CloudMachineSession(machine: machine, appLink: CloudLinkSession(key: CloudLinkKey(machine: machine.id), resolver: resolver),
                                          localIdentity: { [weak local] in local?.identity }, mainWork: mainWork)
        case .legacy:
            guard let hub, let binary else { return nil }
            let link = CloudMachineLink(machineID: machine.id, api: api, hub: hub, paths: paths, binary: binary, deviceName: Self.deviceName)
            session = CloudMachineSession(machine: machine, link: link, mainWork: mainWork)
        }
        session.daemon.workTracker = machines.local.workTracker
        session.daemon.onPaneNotReady = machines.local.onPaneNotReady
        session.daemon.paneNotReadyText = machines.local.paneNotReadyText
        // An attach to a paused machine resumes it through Resume Machine's own path.
        session.resumer = { [weak self] id in try await self?.resumeMachine(id) }
        // An attach reads a record that may be stale (paused behind the app) again first.
        session.refresher = { [weak self] force in
            if force { _ = await self?.refresh() } else { _ = await self?.refresh(ifOlderThan: .seconds(30)) }
        }
        machines.add(session)
        session.connect()
        return session
    }

    private func dropAllMachines() {
        // Account teardown must also fence a mutation that finishes after sign-out.
        // The next permitted refresh re-enables tracking for the current account.
        changes.stop()
        // A list in flight belongs to the machines dropped here.
        listGeneration += 1
        for creation in creations.all { creations.end(creation) }
        for session in machines.cloud { machines.remove(session.machineID)?.disconnect() }
        recordReadApplied = [:]
        recordReadsOutstanding = [:]
        deferredRecordRemovals = [:]
        machines.cloudLimits = nil
        planSizes = []
        hasLoadedMachines = false
        listLoadedAt = nil
    }

    // MARK: Mutations

    /// Creates a machine and connects to it. Returns its session.
    /// `creation` moves to its `creating` stage when the request is sent.
    /// `startedByPerson`: the person's own gesture in this app; any other
    /// create goes out at once on a paid plan (a Free or full plan gets the upgrade card; the opt-in `cloud.askBeforeAgentCreate` asks first) (``CloudMachineCreateFlow``); `askedBy` names the agent chat that asked.
    /// `request`: `cloud new-machine`'s size and idle pause, sent with the create (the legacy
    /// `/api/vm` create only; the app server's create refuses them for now). A server that did
    /// not store the idle pause gets it through `PUT /api/vm/{id}/idle-pause` right after.
    /// `proceed` runs once the server answered, before anything else about the new machine (its
    /// idle pause, joining this Mac's list, connecting): its throw (the account that asked is no
    /// longer signed in) leaves it out.
    func createMachine(name: String?, creation: CloudMachineCreation? = nil, startedByPerson: Bool, askedBy: String? = nil,
                       request: CloudMachineRequest = CloudMachineRequest(), proceed: () throws -> Void = {}) async throws -> CloudMachineSession {
        if let reason = unavailableReason { throw ActionFailure(message: reason) }
        guard auth.isSignedIn else { throw ActionFailure(message: CloudStrings.signInFirst) }
        var name = name ?? request.name
        // The app server's create takes none of them yet, and its machines have no `/api/vm` file
        // or exec route for a bootstrap: refuse rather than make a machine without what was asked.
        if configuration.linkSource == .appServer, !request.isDefault {
            throw ActionFailure(message: CloudStrings.machineOptionsUnavailable)
        }
        // Environments live in the cmux-next backend's CloudDO: the classic `/api/vm` path has none.
        if configuration.linkSource != .appServer, request.environment != nil {
            throw ActionFailure(message: CloudEnvironmentStrings().unavailable)
        }
        // The cmux-next backend stores no name and no slug for an unnamed machine, so it would be titled by
        // its raw id: give it a readable one, unique among this account's machines and creations in flight.
        // The classic `/api/vm` create names it itself (its slug).
        var reserved: String?
        if configuration.linkSource == .appServer {
            if let pinned = creation?.pinnedMachineName {
                name = pinned
            } else if name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                name = CloudMachine.defaultName(
                    taken: machines.cloud.map(\.machine.title) + creations.all.compactMap(\.pinnedMachineName) + machineNamesInFlight,
                    base: CloudStrings.defaultMachineName, numbered: CloudStrings.defaultMachineName(numbered:))
            }
            creation?.pinnedMachineName = name
            // Held until this create ends, typed names included, so a default picked meanwhile is another one.
            reserved = name
            if let name { machineNamesInFlight.append(name) }
        }
        defer { if let reserved, let index = machineNamesInFlight.firstIndex(of: reserved) { machineNamesInFlight.remove(at: index) } }
        creating += 1
        defer { creating -= 1 }
        let onSent: @MainActor @Sendable () async -> Void = { [weak creation] in creation?.note(.creating) }
        let idlePause = request.persistent ? 0 : nil
        var machine = configuration.linkSource == .appServer
            ? try await appServerCreate(name: name, startedByPerson: startedByPerson, askedBy: askedBy, environment: request.environment, creation: creation, request: request, onSent: onSent)
            : try await CloudMachineCreateFlow.legacy(name: name, startedByPerson: startedByPerson, askedBy: askedBy, askFirst: UserDefaults.standard.bool(forKey: "cloud.askBeforeAgentCreate"),
                                                      // A request already sent once (its Retry) goes to the server's lookup of its key, past the local plan gate.
                                                      gate: { [weak self, weak creation] in creation?.request.wasSent == true ? .allowed : self?.createGate ?? .allowed },
                                                      confirm: { [weak self] in await self?.confirmCreate?($0) ?? false },
                                                      create: { [api, weak creation] in
                                                          // The first send's team, for every later call about this machine; a
                                                          // caller that fixed the team (`request.team`) sends every try there.
                                                          let team = await Self.createTeam(sent: creation?.request.wasSent == true ? .some(creation?.request.team) : nil,
                                                                                           requested: request.team, current: { await api.currentTeam() })
                                                          creation?.markRequestSent(team: team)
                                                          return try await api.pinningTeam(team).createWithKey(name: name, request: request, idlePause: idlePause, onSent: onSent)
                                                      })
        logger.info("created machine \(machine.id, privacy: .public)")
        try proceed()
        // The machine exists either way: a failed write leaves its idle pause as the server says,
        // and the answer's `persistent` reads false, so the caller can run `cloud set-idle-pause`.
        if let idlePause, machine.idlePauseMinutes != idlePause {
            do {
                try await api.pinningTeam(creation?.request.team ?? request.team).setIdlePause(machine.id, minutes: idlePause)
                machine.idlePauseMinutes = idlePause
                // A refresh may have listed the machine meanwhile: its session holds the record, and a
                // list read before the PUT must not put the old value back.
                machines.session(machine.id)?.machine.idlePauseMinutes = idlePause
                listGeneration += 1
            } catch {
                logger.error("idle pause for \(machine.id, privacy: .public) not stored: \(String(describing: error), privacy: .public)")
            }
            // The write waited: the account is checked again before the machine joins the list.
            try proceed()
        }
        if let existing = machines.session(machine.id) { existing.sizePick = machine.sizePick ?? existing.sizePick; return existing }
        guard let session = addSession(machine) else { throw ActionFailure(message: CloudStrings.noClient) }
        listedMachineIDs.insert(machine.id)
        // A list in flight was asked before this machine existed.
        listGeneration += 1
        return session
    }

    /// The team a classic create try goes to: the first send's once one was sent (`sent`), else the
    /// team the caller fixed (`requested`, ``CloudMachineRequest/team``), else the app's team now.
    nonisolated static func createTeam(sent: String??, requested: String?, current: () async -> String?) async -> String? {
        if let sent { return sent }
        if let requested { return requested }
        return await current()
    }
    /// Kill, Pause and Resume show their transition from the click until the next list settles it.
    func deleteMachine(_ machineID: String) async throws {
        // Retain credentials and broker registration until a list confirms removal. Both
        // the request and the asynchronous provider deletion can still fail.
        try await changes.run(.deleting, machineID: machineID, of: { machines.session(machineID) },
                              onRollback: { [weak self] id in self?.machines.session(machineID)?.mutationFailed(id) }) {
            try await api.deleteMachine(machineID)
        }
        // A list in flight was asked while this machine still existed.
        listGeneration += 1
        creations.machineRemoved(machineID)
        if let session = machines.session(machineID) { session.retainForDeleteTransition() }; changes.began { [weak self] in _ = await self?.refresh() }
        logger.info("deleted machine \(machineID, privacy: .public)")
    }

    func pauseMachine(_ machineID: String) async throws {
        try await changes.run(.pausing, machineID: machineID, of: { machines.session(machineID) },
                              onRollback: { [weak self] id in self?.machines.session(machineID)?.mutationFailed(id) }) {
            try await api.pauseMachine(machineID)
        }
        changes.began { [weak self] in _ = await self?.refresh() }; await refresh(); logger.info("paused machine \(machineID, privacy: .public)")
    }

    func resumeMachine(_ machineID: String) async throws {
        try await changes.run(.starting, machineID: machineID, of: { machines.session(machineID) },
                              onRollback: { [weak self] id in self?.machines.session(machineID)?.mutationFailed(id) }) {
            try await api.resumeMachine(machineID)
        }
        changes.began { [weak self] in _ = await self?.refresh() }; await refresh(); logger.info("resumed machine \(machineID, privacy: .public)")
    }

    /// The machine's idle auto-pause (`PUT /api/vm/{id}/idle-pause`): minutes
    /// of idle before cmux Cloud pauses it; 0 is Off.
    func setIdlePause(_ machineID: String, minutes: Int) async throws {
        try await api.setIdlePause(machineID, minutes: minutes)
        machines.session(machineID)?.machine.idlePauseMinutes = minutes
        logger.info("set idle pause \(machineID, privacy: .public) to \(minutes) min")
    }

    /// Starts the WireGuard hub once signed in when `cloud enroll-machine` wrote ssh routes that
    /// dial through it (``CloudPaths/sshRoutesMarker``); without the hub those routes fail.
    /// Called after each machine list refresh (sign-in, Cloud re-enabled, the periodic list), so a hub
    /// that failed to start (offline at launch) or to restart gets another try; a running hub
    /// answers at once. Never while Cloud is unavailable (a team policy, a local backend).
    func startHubForSSHRoutes() async {
        guard unavailableReason == nil, auth.isSignedIn else { return }
        guard let hub, (try? await work.run(.userVisible, mayBlock: .files) { [paths] in paths.hasSSHRoutes() }) == true else { return }
        // Cloud may have been turned off while the check waited: then no hub starts.
        guard unavailableReason == nil, auth.isSignedIn else { return }
        do { _ = try await hub.linkedSocketPath() } catch { logger.error("wireguard hub for ssh routes: \(String(describing: error), privacy: .public)") }
    }

    func renameMachine(_ machineID: String, to name: String) async throws {
        try await api.renameMachine(machineID, to: name.isEmpty ? nil : name)
        machines.session(machineID)?.machine.displayName = name.isEmpty ? nil : name
    }

    /// Runs when a sign-out starts, while the account's tokens still work
    /// (the device hub signs this Mac out of its sessions at once).
    var willSignOut: [@MainActor () -> Void] = []

    func signOut() async {
        signedOutCreation.cancel()
        // Start-session asks and runs end now, not after the link and install cleanup below.
        startSessionRuns.forgetAll()
        startSessionAsks.endAll()
        for hook in willSignOut { hook() }
        await codexBroker.signOut()
        AgentPaneTailCache.shared.clear() // the panes' chat tails: memory only, forgotten whole
        // No ensure starts from here until the session's final endLink (the
        // signed-out branch above, after auth.signOut).
        link.beginEnding()
        dropAllMachines()
        await link.endLink(final: false)
        desktopRdTokens.removeAll()
        if let hub { await hub.revoke() }
        // Revoke the install while the Stack session still exists.
        if let stackUser = auth.user?.id {
            let auth = auth
            await installIdentity.signOut(stackUser: stackUser, session: { try await auth.tokens().access })
            if shareInstallIdentity !== installIdentity {
                await shareInstallIdentity.signOut(stackUser: stackUser, session: { try await auth.tokens().access })
            }
        }
        // An ensure that slipped in during the revoke: stop that link too.
        await link.stopLink()
        await auth.signOut()
    }

    /// Starts this Mac's `cmux link` (``CloudLinkLifecycle/ensureLink()``).
    func ensureLink() async { await link.ensureLink() }

    /// ``CloudLinkLifecycle/ensureLinkReport()``, for the DEBUG socket method.
    func ensureLinkReport() async -> JSONValue { await link.ensureLinkReport() }

    /// Registers (or reuses) this Mac's install for the signed-in user and
    /// mints one token. A failure is logged: the relay mints again when it
    /// needs a token, and the hub path does not depend on it.
    private func installSignedIn() async {
        guard let stackUser = auth.user?.id, mayCallCloud else { return }
        let auth = auth
        do {
            try await installIdentity.signedIn(stackUser: stackUser, session: { try await auth.tokens().access })
            hostReplica.installReady()
        } catch {
            logger.error("install registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A guest link's owner token from ``shareInstallIdentity``, registering that install first when sign-in
    /// did not: a DEV build on the local backend never calls the Cloud API (``mayCallCloud``), but its links'
    /// room is a Worker's. Nil signed out, or with Cloud off for the organization or its team missing.
    func shareOwnerToken() async -> String? {
        guard let stackUser = auth.user?.id, !policyDisabled, auth.managedTeamID == nil || auth.teamID != nil else { return nil }
        let auth = auth
        do {
            try await shareInstallIdentity.signedIn(stackUser: stackUser, session: { try await auth.tokens().access })
            return try await shareInstallIdentity.installToken()
        } catch {
            logger.error("share owner token failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
