import CmuxAuthRuntime
import CmuxSettings
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
    /// for; a change tears it down and builds a fresh one.
    private var identity: AuthenticatedSessionIdentity?
    private var teamID: String?
    private var providers: [SurfaceDeviceInstanceID: DeviceSurfaceProvider] = [:]
    private var directoryObserver: NSObjectProtocol?
    private var authorizationObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var accessObserver: NSObjectProtocol?
    private var policyObserver: NSObjectProtocol?
    typealias DirectoryFactory = @MainActor (
        AuthCoordinator, AuthenticatedSessionIdentity, String?, any DeviceLinkAuthorizationSource, DeviceIrxClient?
    ) -> DeviceDirectory

    private let makeDirectory: DirectoryFactory
    private let isFeatureEnabled: @MainActor () -> Bool
    private let makeAutomaticClient: @MainActor (AuthenticatedSessionIdentity, String?) -> DeviceIrxClient?
    private let allowsAutomaticConnections: @MainActor () -> Bool
    private var activeAutomaticConnections = false

    init(
        preferences: DevicesPreferencesModel? = nil,
        makeAutomaticClient: @escaping @MainActor (AuthenticatedSessionIdentity, String?) -> DeviceIrxClient? = { _, _ in nil },
        allowsAutomaticConnections: @escaping @MainActor () -> Bool = { false },
        makeDirectory: @escaping DirectoryFactory = { auth, identity, teamID, pairing, automaticClient in
            DeviceDirectory(auth: auth, identity: identity, teamID: teamID, pairing: pairing, automaticClient: automaticClient)
        },
        isFeatureEnabled: @escaping @MainActor () -> Bool = { DevicesFeature.isDiscoveryEnabled() }
    ) {
        self.preferences = preferences
        self.makeAutomaticClient = makeAutomaticClient
        self.allowsAutomaticConnections = allowsAutomaticConnections
        self.makeDirectory = makeDirectory
        self.isFeatureEnabled = isFeatureEnabled
    }

    deinit {
        for observer in [directoryObserver, authorizationObserver, defaultsObserver, accessObserver, policyObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
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
        let center = NotificationCenter.default
        if let authorizationObserver { center.removeObserver(authorizationObserver) }
        authorizationObserver = center.addObserver(forName: authorization.authorizationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.authorizationDidChange() }
        }
        if let defaultsObserver { center.removeObserver(defaultsObserver) }
        defaultsObserver = center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
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
    /// it, and an account or team switch rebuilds it under the new scope.
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
        let identity = auth.authenticatedSessionIdentity
        let teamID = auth.resolvedTeamID
        let shouldRun = isFeatureEnabled() && identity != nil
        let automatic = allowsAutomaticConnections()
        let scopeChanged = identity != self.identity || teamID != self.teamID || automatic != activeAutomaticConnections
        if directory != nil, !shouldRun || scopeChanged {
            if let directoryObserver { NotificationCenter.default.removeObserver(directoryObserver) }
            directoryObserver = nil
            directory?.stop()
            directory = nil
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
        directoryObserver = NotificationCenter.default.addObserver(
            forName: DeviceDirectory.didChangeNotification,
            object: directory,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        directory.start()
        reconcile()
    }

    /// Settings › Computers "Open": show this device's row in the Devices tab,
    /// expanded and selected, even if it was collapsed. Never opens a terminal.
    /// The panel consumes the request when it is (or becomes) mounted, so the
    /// caller may switch the sidebar mode first and reveal right after.
    func reveal(instance: SurfaceDeviceInstanceID, windowID: UUID? = nil) {
        if let windowID { pendingWindowReveals[windowID] = instance }
        else { pendingReveal = instance }
        NotificationCenter.default.post(
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
                let link = DeviceLink(record: record, runtime: runtime, authorization: authorization)
                let provider = DeviceSurfaceProvider(record: record, link: link, catalog: catalog)
                providers[record.instance] = provider
                catalog.register(provider)
                provider.update(record: record)
            }
        }
    }
}
