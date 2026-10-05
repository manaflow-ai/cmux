import CmuxCloud
import CmuxAuthRuntime
import CmuxFoundation
import CmuxSettings
import CmuxSurfaceCatalogModel
import Foundation
import Observation

/// Owns one ``DeviceSurfaceProvider`` per other Mac on the account and keeps
/// the catalog's device machines in step with the ``DeviceDirectory``:
/// registers a provider when a device appears, updates it on every presence,
/// route, or pairing change, and unregisters it when the directory drops it.
/// Runs only while discovery is on and the account is signed in;
/// signing out or turning discovery off tears everything down.
@MainActor
final class DeviceSurfaceProviderRegistry {
    let preferences: DevicesPreferencesModel?
    /// Every link's state history, for Cloud Diagnostics and the persisted journal.
    let diagnostics: DeviceLinkDiagnostics
    /// Posted by ``reveal(instance:)``; the mounted Devices panel consumes the
    /// pending request on it (userInfo `instance`: the wire value).
    static let revealDeviceNotification = Notification.Name("cmux.devices.revealDevice")
    private(set) var pendingReveal: SurfaceDeviceInstanceID?
    private var pendingWindowReveals: [UUID: SurfaceDeviceInstanceID] = [:]

    private var catalog: SurfaceCatalog?
    private var auth: AuthCoordinator?
    private(set) var directory: DeviceDirectory?
    private var runtime: DeviceLinkRuntime?
    private var authorization: (any DeviceLinkAuthorizationSource)?
    /// The account generation and team scope the running directory was built
    /// for. An account change tears everything down; a team change alone swaps
    /// the team-scoped pieces in place (see ``swapTeam(to:)``).
    private var identity: AuthenticatedSessionIdentity?
    private var teamID: String?
    private var providers: [SurfaceDeviceInstanceID: DeviceSurfaceProvider] = [:]
    /// The last directory stamp forwarded to links; an advance retries host refusals once.
    private var lastDirectoryStamp: DeviceDirectoryStamp?
    private var directoryObserver: NSObjectProtocol?
    private var authorizationObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var availabilityObserver: CloudFeatureAvailabilityObserver?
    private var accessObserver: NSObjectProtocol?
    private var policyObserver: NSObjectProtocol?
    typealias DirectoryFactory = @MainActor (
        AuthCoordinator, AuthenticatedSessionIdentity, String?, any DeviceLinkAuthorizationSource, DeviceIrxClient?
    ) -> DeviceDirectory

    private let notificationCenter: NotificationCenter
    private let sessionScope: @MainActor (AuthCoordinator) -> (AuthenticatedSessionIdentity?, String?)
    private let makeDirectory: DirectoryFactory
    private let isFeatureEnabled: @MainActor () -> Bool
    private let makeAutomaticClient: @MainActor (AuthenticatedSessionIdentity, String?) -> DeviceIrxClient?
    private let allowsAutomaticConnections: @MainActor () -> Bool
    /// Whether a team switch keeps My Devices in place: only while the
    /// per-user account directory owns membership. Off (its flag), a team
    /// switch rebuilds exactly as before.
    private let swapsTeamInPlace: @MainActor () -> Bool
    private var activeAutomaticConnections = false

    init(
        preferences: DevicesPreferencesModel? = nil,
        diagnostics: DeviceLinkDiagnostics = DeviceLinkDiagnostics(),
        notificationCenter: NotificationCenter = .default,
        sessionScope: @escaping @MainActor (AuthCoordinator) -> (AuthenticatedSessionIdentity?, String?) = {
            ($0.authenticatedSessionIdentity, $0.resolvedTeamID)
        },
        makeAutomaticClient: @escaping @MainActor (AuthenticatedSessionIdentity, String?) -> DeviceIrxClient? = { _, _ in nil },
        allowsAutomaticConnections: @escaping @MainActor () -> Bool = { false },
        swapsTeamInPlace: @escaping @MainActor () -> Bool = { AccountMacDirectoryFeature.isEnabled() },
        makeDirectory: @escaping DirectoryFactory = { auth, identity, teamID, pairing, automaticClient in
            DeviceDirectory(auth: auth, identity: identity, teamID: teamID, pairing: pairing, automaticClient: automaticClient)
        },
        isFeatureEnabled: @escaping @MainActor () -> Bool = { DevicesFeature.isDiscoveryEnabled() }
    ) {
        self.notificationCenter = notificationCenter
        self.sessionScope = sessionScope
        self.preferences = preferences
        self.diagnostics = diagnostics
        self.makeAutomaticClient = makeAutomaticClient
        self.allowsAutomaticConnections = allowsAutomaticConnections
        self.swapsTeamInPlace = swapsTeamInPlace
        self.makeDirectory = makeDirectory
        self.isFeatureEnabled = isFeatureEnabled
    }

    deinit {
        for observer in [directoryObserver, authorizationObserver, defaultsObserver, accessObserver, policyObserver] {
            if let observer { notificationCenter.removeObserver(observer) }
        }
    }

    var isRunning: Bool { directory?.isRunning ?? false }
    var providerCount: Int { providers.count }

    func provider(for instance: SurfaceDeviceInstanceID) -> DeviceSurfaceProvider? {
        providers[instance]
    }

    /// Composition root entry: inject auth, the catalog, and the pairing store
    /// once, then follow the discovery preference, managed policy, sign-in state, and
    /// pairing changes from here on.
    func configure(auth: AuthCoordinator, catalog: SurfaceCatalog, authorization: any DeviceLinkAuthorizationSource) {
        self.auth = auth
        self.catalog = catalog
        self.authorization = authorization
        let center = notificationCenter
        if let authorizationObserver { center.removeObserver(authorizationObserver) }
        authorizationObserver = center.addObserver(forName: authorization.authorizationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.authorizationDidChange() }
        }
        if let defaultsObserver { center.removeObserver(defaultsObserver) }
        defaultsObserver = center.addUserDefaultsObserver(object: UserDefaults.standard) { [weak self] in
            self?.evaluate()
        }
        availabilityObserver = CloudFeatureAvailabilityObserver(notificationCenter: notificationCenter, isEnabled: isFeatureEnabled) { [weak self] _ in
            self?.evaluate()
        }
        if let policyObserver { center.removeObserver(policyObserver) }
        policyObserver = center.addObserver(forName: ManagedDevicePolicy.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        if let accessObserver { center.removeObserver(accessObserver) }
        accessObserver = center.addObserver(forName: .cmuxCloudVMAccessDidEnd, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        observeAuth()
        evaluate()
    }

    /// Tracks the authenticated session identity and team scope, so sign-in
    /// starts the directory without a panel having to be open, sign-out stops
    /// it, an account switch rebuilds it, and a team switch swaps its
    /// team-scoped pieces in place.
    private func observeAuth() {
        guard let auth else { return }
        withObservationTracking {
            _ = auth.authenticatedSessionIdentity
            _ = auth.resolvedTeamID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.evaluate()
                self?.observeAuth()
            }
        }
    }

    /// Start, stop, or rebuild to match the gate: feature on and signed in,
    /// under the current account generation and team scope.
    func evaluate() {
        guard let auth, let catalog, let authorization else { return }
        let (identity, teamID) = sessionScope(auth)
        let shouldRun = isFeatureEnabled() && identity != nil
        let automatic = allowsAutomaticConnections()
        // With the per-user directory, My Devices membership is the account's,
        // so only the account, the gate, or automatic connections rebuild it;
        // a team change swaps the team-scoped pieces in place.
        let inPlace = swapsTeamInPlace()
        let scopeChanged = identity != self.identity || automatic != activeAutomaticConnections
            || (!inPlace && teamID != self.teamID)
        if directory != nil, shouldRun, !scopeChanged, teamID != self.teamID, let identity {
            swapTeam(to: teamID, auth: auth, identity: identity, authorization: authorization)
            return
        }
        if directory != nil, !shouldRun || scopeChanged {
            if let directoryObserver { notificationCenter.removeObserver(directoryObserver) }
            directoryObserver = nil
            directory?.stop()
            directory = nil
            lastDirectoryStamp = nil
            if let client = runtime?.automaticClient { Task { await client.stop() } }
            runtime = nil
            for (instance, provider) in providers {
                provider.stop()
                catalog.unregister(machine: .device(instance))
            }
            providers.removeAll()
        }
        guard shouldRun, directory == nil, let identity else {
            if !shouldRun {
                self.identity = nil
                self.teamID = nil
            }
            return
        }
        self.identity = identity
        self.teamID = teamID
        activeAutomaticConnections = automatic
        runtime = DeviceLinkRuntime(
            tokens: HiveAccountTokenSource(auth: auth, identity: identity, teamID: teamID),
            automaticClient: automatic ? makeAutomaticClient(identity, teamID) : nil
        )
        let directory = makeDirectory(auth, identity, teamID, authorization, runtime?.automaticClient)
        self.directory = directory
        directoryObserver = notificationCenter.addObserver(
            forName: DeviceDirectory.didChangeNotification,
            object: directory,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        directory.start()
        reconcile()
    }

    /// A team switch for the same account: replace the team-scoped directory
    /// sources, tokens and automatic client, carry the rows over, and point
    /// every existing link at the new runtime. No provider is unregistered,
    /// so the rows stay visible while links redial under the new team.
    private func swapTeam(
        to teamID: String?,
        auth: AuthCoordinator,
        identity: AuthenticatedSessionIdentity,
        authorization: any DeviceLinkAuthorizationSource
    ) {
        guard let previous = directory else { return }
        let carried = previous.carriedState()
        let oldClient = runtime?.automaticClient
        if let directoryObserver { notificationCenter.removeObserver(directoryObserver) }
        directoryObserver = nil
        self.teamID = teamID
        let runtime = DeviceLinkRuntime(
            tokens: HiveAccountTokenSource(auth: auth, identity: identity, teamID: teamID),
            automaticClient: activeAutomaticConnections ? makeAutomaticClient(identity, teamID) : nil
        )
        self.runtime = runtime
        let next = makeDirectory(auth, identity, teamID, authorization, runtime.automaticClient)
        next.adopt(carried)
        directory = next
        lastDirectoryStamp = nil
        // Links move to the new runtime before the old client stops, so a
        // session ending under the old team is already a stale generation.
        for provider in providers.values { provider.link.replaceRuntime(runtime) }
        previous.stop()
        if let oldClient { Task { await oldClient.stop() } }
        directoryObserver = notificationCenter.addObserver(
            forName: DeviceDirectory.didChangeNotification,
            object: next,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        next.start()
        reconcile()
    }

    /// Settings › Devices "Open": show this device's row in the Devices tab,
    /// expanded and selected, even if it was collapsed. Never opens a terminal.
    /// The panel consumes the request when it is (or becomes) mounted, so the
    /// caller may switch the sidebar mode first and reveal right after.
    func reveal(instance: SurfaceDeviceInstanceID, windowID: UUID? = nil) {
        if let windowID { pendingWindowReveals[windowID] = instance }
        else { pendingReveal = instance }
        notificationCenter.post(
            name: Self.revealDeviceNotification,
            object: nil,
            userInfo: ["instance": instance.wireValue]
        )
    }

    func takePendingReveal(windowID: UUID? = nil) -> SurfaceDeviceInstanceID? {
        if let windowID, let instance = pendingWindowReveals.removeValue(forKey: windowID) {
            return instance
        }
        defer { pendingReveal = nil }
        return pendingReveal
    }

    /// A pairing was added or removed: every link re-evaluates its grant.
    func authorizationDidChange() {
        for provider in providers.values {
            provider.authorizationDidChange()
        }
    }

    /// The explicit Refresh verb: re-read the registry and re-sync every live link.
    func refresh(force: Bool) async {
        let registryRefresh = directory?.refreshRegistry()
        await withTaskGroup(of: Void.self) { group in
            for provider in providers.values {
                group.addTask { @MainActor in await provider.refresh(force: force) }
            }
        }
        await registryRefresh?.value
    }

    private func reconcile() {
        guard let directory, let catalog, let runtime, let authorization else { return }
        let records = Dictionary(directory.records.map { ($0.instance, $0) }, uniquingKeysWith: { first, _ in first })
        for (instance, provider) in providers where records[instance] == nil {
            provider.stop()
            providers[instance] = nil
            catalog.unregister(machine: .device(instance))
        }
        for record in directory.records {
            if let provider = providers[record.instance] {
                provider.update(record: record)
            } else {
                let link = DeviceLink(record: record, runtime: runtime, authorization: authorization, diagnostics: diagnostics)
                let provider = DeviceSurfaceProvider(record: record, link: link, catalog: catalog)
                providers[record.instance] = provider
                catalog.register(provider)
                provider.update(record: record)
            }
        }
        if let stamp = directory.directoryStamp {
            if let last = lastDirectoryStamp, stamp.advanced(since: last) {
                for provider in providers.values { provider.directoryRevisionAdvanced() }
            }
            lastDirectoryStamp = stamp
        }
    }
}
