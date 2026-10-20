import AppKit
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Observation
import os

/// Cloud orchestration: sign-in state, the machine list from `/api/vm`, and
/// one `CloudMachineSession` per live machine in `MachineRegistry`. The
/// list is fetched when the session restores or signs in, after every
/// machine mutation, and when the app becomes active (at most every 30 s);
/// there is no polling timer.
@Observable
final class CloudService {
    let configuration: CloudConfiguration
    let auth: CloudAuth
    @ObservationIgnored let cloudTeam: CloudTeamSelection
    @ObservationIgnored let teamScope: CloudTeamScope
    @ObservationIgnored let api: CloudAPIClient
    @ObservationIgnored let paths: CloudPaths
    @ObservationIgnored private(set) var hub: CloudTunnelHub?
    /// This Mac's Cloud install principal (cx-wb5.64): install tokens for the
    /// credential relay; registered at sign-in, revoked at sign-out.
    @ObservationIgnored let installIdentity: MacInstallIdentity
    /// Chief hands: levels, the presence key and requests waiting for the owner (cx-om025).
    @ObservationIgnored let hands: HandsService
    @ObservationIgnored let machines: MachineRegistry
    @ObservationIgnored private let binary: URL?
    /// The selected team's app-owned Native link; the legacy configuration uses only its tunnel hub.
    @ObservationIgnored var nativeLink: NativeCloudLinkOwner?
    @ObservationIgnored var sessionLifecycle: CloudSessionLifecycle?
    @ObservationIgnored var machineScope: String?
    @ObservationIgnored private var lastRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    /// The local side event subscription for `cloud.link.changed` (app link).
    @ObservationIgnored private var linkEvents: UInt64?
    /// The `credential` provider family on the local daemon (cx-wb5.63):
    /// app servers' Cloud API calls, sent with the install token.
    @ObservationIgnored var credentialProvider: CloudCredentialProvider?
    @ObservationIgnored private(set) var isSigningOut = false
    @ObservationIgnored private var credentialEvents: UInt64?
    @ObservationIgnored let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
    /// The last list or connection failure, for diagnostics and refusals.
    private(set) var lastError: String?
    private(set) var hasLoadedMachines = false
    /// The Cloud app server's ops on the local daemon (contract 2.1).
    func appOps(_ scope: CloudTeamScope.Snapshot) -> CloudAppOp { CloudAppLinks.ops(local: machines.local, scope: scope) }
    /// The cmux window a create's native confirmation attaches to (set by AppServices).
    @ObservationIgnored var confirmWindow: (@MainActor () -> NSWindow?)?
    /// Machine creations in flight (sidebar can show a placeholder).
    private(set) var creating = 0
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
    /// Moved chats' file requests for this Mac, asked in their chats.
    @ObservationIgnored let accessAsks = CloudAccessAsks()
    /// Files the person drops or pastes into a moved chat, sent to its machine (``CloudUploads``).
    @ObservationIgnored let uploads = CloudUploads()

    init(machines: MachineRegistry, isDebugBuild: Bool) {
        self.machines = machines
        configuration = CloudConfiguration.current(isDebugBuild: isDebugBuild)
        auth = CloudAuth(configuration: configuration)
        cloudTeam = CloudTeamSelection(auth: auth, configuration: configuration)
        paths = CloudPaths.standard(bundleID: configuration.bundleID)
        let auth = auth
        api = CloudAPIClient(
            configuration: configuration,
            tokens: { try await auth.tokens() },
            teamID: { await auth.teamID }
        )
        installIdentity = MacInstallIdentity(
            store: .forApp(directory: paths.root.appendingPathComponent("install", isDirectory: true),
                           service: "\(configuration.bundleID ?? "cmux").install-key.\(configuration.ownerAPIBaseURL().host ?? "unknown")",
                           team: CodeSigningTeam.current(), isDebugBuild: configuration.isDebugBuild),
            transport: InstallHTTPTransport(baseURL: configuration.ownerAPIBaseURL()),
            deviceName: Self.deviceName,
            clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        hands = HandsService(
            apiBaseURL: configuration.ownerAPIBaseURL(), accessToken: { [auth] in try await auth.tokens().access }, identity: installIdentity,
            presence: HandPresenceKeyStore(directory: paths.root.appendingPathComponent("install", isDirectory: true)))
        let identity = installIdentity
        let transport = InstallHTTPTransport(baseURL: configuration.ownerAPIBaseURL())
        let selection = cloudTeam
        let scope = CloudTeamScope(identity: identity, transport: transport,
            selection: { try await selection.current() }, session: { try await auth.tokens().access })
        teamScope = scope
        binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)
        move.cli = binary
        move.ledger = .standard
        if configuration.linkSource == .legacy, let binary {
            hub = CloudTunnelHub(api: api, paths: paths, binary: binary, deviceName: Self.deviceName)
        }
        movedChats.defaults = { [weak self] in self?.move.ledger }
        moveRetries.defaults = { [weak self] in self?.move.ledger }
        bringBackRetries.defaults = { [weak self] in self?.move.ledger }
        moveAsks.defaults = { [weak self] in self?.move.ledger }
        CloudMovedChats.app = movedChats
        if configuration.linkSource == .appServer {
            let factory = NativeCloudLinkFactory(identity: identity, paths: paths, bundle: Bundle.main.bundleURL,
                home: FileManager.default.homeDirectoryForCurrentUser, session: { try await auth.tokens().access }, name: Self.deviceName)
            nativeLink = NativeCloudLinkOwner(make: { try await factory.make($0) }, invalidate: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.invalidateNativeLink()
            })
        }
        credentialProvider = CloudCredentialOwner(auth: auth, identity: identity, scope: scope, transport: transport, native: nativeLink).provider
        sessionLifecycle = makeSessionLifecycle()
    }

    var isSignedIn: Bool { auth.isSignedIn }

    /// Why Cloud cannot run in this build, or nil.
    var unavailableReason: String? {
        if policyDisabled { return RefusalStrings.turnedOffByOrganization }
        // RestrictToManagedTeam (P17-3): no request goes out without the managed team.
        if auth.managedTeamID != nil, auth.teamID == nil { return RefusalStrings.turnedOffByOrganization }
        // The app server path needs no web backend (cx-t2rz): only the legacy /api/vm path does.
        if case .localOnly = configuration.backend, configuration.linkSource == .legacy { return CloudStrings.localBackend }
        if binary == nil { return CloudStrings.noClient }
        return nil
    }

    func start() {
        auth.start()
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
            guard let self, let lifecycle = self.sessionLifecycle else { return }
            let identities = auth.coordinator.authenticatedSessionIdentities()
            await auth.awaitRestored()
            for await identity in identities {
                guard !Task.isCancelled else { return }
                await lifecycle.update(identity).value
            }
        })
        observers.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self, let last = self.lastRefresh, last.duration(to: .now) > .seconds(30) else { continue }
                await self.refresh()
            }
        })
    }

    /// Turning Cloud off disconnects every machine and keeps its workspaces
    /// (their terminals show "Turned off by your organization"); the VMs
    /// keep running. Turning it on again reconnects from a fresh list.
    func applyPolicy(disabled: Bool) {
        guard disabled != policyDisabled else { return }
        cloudTeam.policyDisabled = disabled
        if disabled {
            for session in machines.cloud {
                session.daemon.policyBlock.set(true)
                session.disconnect()
            }
            // The local tunnel hub stops too; nothing is revoked remotely.
            // task-owner: one teardown hop; hub.stop() is idempotent
            if let hub { Task { await hub.stop() } }
            // So does this Mac's link (the session stays).
            if let nativeLink { observers.append(Task { await nativeLink.retire() }) }
        } else {
            dropAllMachines()
            // task-owner: one list fetch after the policy lifted
            Task { [weak self] in
                guard let self, auth.isSignedIn else { return }
                await sessionLifecycle?.refresh(auth.coordinator.authenticatedSessionIdentity).value
            }
        }
    }

    func stop() {
        _ = sessionLifecycle?.stop()
        for observer in observers { observer.cancel() }
        observers.removeAll()
        if let linkEvents { machines.local.store.sideEvents.unsubscribe(linkEvents) }
        linkEvents = nil
        if let credentialEvents { machines.local.store.sideEvents.unsubscribe(credentialEvents) }
        credentialEvents = nil
        credentialProvider?.suspend()
        // task-owner: teardown at quit; the owner joins its child without deleting the reusable enrollment.
        if let nativeLink { Task { await nativeLink.suspend() } }
        for session in machines.cloud { session.disconnect() }
        // task-owner: teardown hop at quit; hub.stop() is idempotent
        if let hub { Task { await hub.stop() } }
    }

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
                guard case .connected = state, let connection = local.connection else { provider.stop(); continue }
                let allowed = await connection.userOriginAllowed
                _ = await provider.register(userOriginAllowed: allowed,
                    send: { try await connection.request($0) }, invalidate: { try await connection.request($0) })
            }
        })
        let selection = cloudTeam
        let changes = ObservationStream.current { try? selection.current() }.later
        // task-owner: observers; closes idle resources even when no Cloud operation follows the change.
        observers.append(Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.dropAllMachines()
                if let nativeLink = self.nativeLink { await nativeLink.retire(); continue }
                guard let connection = local.connection else { provider.stop(); continue }
                await provider.scopeChanged { try await connection.request($0) }
            }
        })
    }

    // MARK: Machine list

    /// Fetches `/api/vm` and reconciles sessions: new live machines connect,
    /// gone machines disconnect, records update in place.
    func refresh() async {
        guard let identity = auth.coordinator.authenticatedSessionIdentity,
              isCloudSessionCurrent(identity), unavailableReason == nil else { return }
        lastRefresh = .now
        do {
            let scope: CloudTeamScope.Snapshot? = configuration.linkSource == .appServer ? try await teamScope.snapshot() : nil
            let list = if let scope { try await appServerMachines(scope: scope) } else { try await api.listMachines() }
            guard isCloudSessionCurrent(identity) else { return }
            if let scope { try await scope.recheck(); try cloudTeam.check(scope) }
            if machineScope != scope?.id { dropAllMachines() }
            machineScope = scope?.id
            lastError = nil
            reconcile(list, scope: scope)
            hasLoadedMachines = true
        } catch {
            lastError = String(describing: error)
            logger.error("machine list failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func reconcile(_ list: [CloudMachine], scope: CloudTeamScope.Snapshot?) {
        // A list that arrives after Cloud was turned off connects nothing.
        guard !policyDisabled else { return }
        let visible = list.filter { $0.status != .destroyed }
        for machine in visible {
            if let session = machines.session(machine.id) {
                let wasLive = session.machine.status.isLive
                session.machine = machine
                if wasLive, !machine.status.isLive {
                    session.suspend()
                } else if !wasLive, machine.status.isLive {
                    session.connect()
                }
            } else {
                addSession(machine, scope: scope)
            }
        }
        let ids = Set(visible.map(\.id))
        for session in machines.cloud where !ids.contains(session.machineID) {
            creations.machineRemoved(session.machineID)
            machines.remove(session.machineID)?.disconnect()
        }
    }

    @discardableResult
    private func addSession(_ machine: CloudMachine, scope: CloudTeamScope.Snapshot?) -> CloudMachineSession? {
        guard !policyDisabled else { return nil }
        let session: CloudMachineSession
        switch configuration.linkSource {
        case .appServer:
            guard let scope else { return nil }
            let resolver = CloudConnectOpResolver(run: CloudAppLinks.runner(local: machines.local, scope: scope))
            let local = machines.local
            session = CloudMachineSession(machine: machine, appLink: CloudLinkSession(key: CloudLinkKey(machine: machine.id), resolver: resolver),
                                          localIdentity: { [weak local] in local?.identity })
        case .legacy:
            guard let hub, let binary else { return nil }
            let link = CloudMachineLink(machineID: machine.id, api: api, hub: hub, paths: paths, binary: binary, deviceName: Self.deviceName)
            session = CloudMachineSession(machine: machine, link: link)
        }
        session.daemon.workTracker = machines.local.workTracker
        machines.add(session)
        session.connect()
        return session
    }

    func dropAllMachines() {
        for creation in creations.all { creations.remove(creation) }
        for session in machines.cloud { machines.remove(session.machineID)?.disconnect() }
        hasLoadedMachines = false
    }

    // MARK: Mutations

    /// Creates a machine and connects to it. Returns its session.
    /// `creation` moves to its `creating` stage when the request is sent.
    /// `startedByPerson`: the person's own gesture in this app; on the app
    /// server path any other create asks the person first
    /// (``CloudMachineCreateFlow``).
    func createMachine(name: String?, creation: CloudMachineCreation? = nil, startedByPerson: Bool) async throws -> CloudMachineSession {
        if let reason = unavailableReason { throw ActionFailure(message: reason) }
        guard auth.isSignedIn else { throw ActionFailure(message: CloudStrings.signInFirst) }
        creating += 1
        defer { creating -= 1 }
        let onSent: @MainActor @Sendable () async -> Void = { [weak creation] in creation?.note(.creating) }
        let scope: CloudTeamScope.Snapshot? = configuration.linkSource == .appServer ? try await teamScope.snapshot() : nil
        let machine: CloudMachine
        if let scope {
            machine = try await appServerCreate(name: name, startedByPerson: startedByPerson, scope: scope, onSent: onSent)
            try await scope.recheck(); try cloudTeam.check(scope)
        } else { machine = try await api.createMachine(displayName: name, onSent: onSent) }
        if machineScope != scope?.id { dropAllMachines() }
        machineScope = scope?.id
        logger.info("created machine \(machine.id, privacy: .public)")
        if let existing = machines.session(machine.id) { return existing }
        guard let session = addSession(machine, scope: scope) else { throw ActionFailure(message: CloudStrings.noClient) }
        return session
    }

    func signOut() async {
        guard !isSigningOut else { return }
        let stackUser = auth.user?.id, generation = auth.coordinator.authSessionGeneration
        isSigningOut = true
        defer { isSigningOut = false }
        if let sessionLifecycle { await sessionLifecycle.suspend().value }
        else { await retireCloudSession(.session) }
        if let hub { await hub.revoke() }
        // Revoke the install while the Stack session still exists.
        if let stackUser {
            let auth = auth
            await installIdentity.signOut(stackUser: stackUser, session: {
                guard await auth.coordinator.authSessionGeneration == generation else { throw CancellationError() }
                let token = try await auth.tokens().access
                guard await auth.coordinator.authSessionGeneration == generation else { throw CancellationError() }
                return token
            })
        }
        await auth.signOut(ifGeneration: generation)
        isSigningOut = false
        await sessionLifecycle?.resume(auth.coordinator.authenticatedSessionIdentity).value
    }

    /// Ensures the selected team's owned child before a scoped connect.
    func ensureLink() async { _ = await ensureLinkReport() }

    /// Reports owned Native startup for the DEBUG socket method.
    func ensureLinkReport() async -> JSONValue { await ensureNativeLinkReport() }


}
