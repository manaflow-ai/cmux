import CmuxExtensionKit
import CmuxControlSocket
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import Darwin
import Foundation

/// A synchronous authorization projection for the socket worker.
enum CmuxPluginSocketAuthorization: Sendable, Equatable {
    case allowed(Set<String>)
    case denied(String)
}

/// Control-socket handling required for one peer and request shape.
enum CmuxPluginSocketPeerPolicy: Sendable, Equatable {
    case standard
    case pluginEventStream
    case denied
}

/// Composition-root adapter for the actor-backed package plugin registry.
///
/// Sendable safety: the control-socket reader is a synchronous, nonisolated
/// callback, so its authorization snapshot, supervised-process identities,
/// and subscription revocations share one short critical section. Every access
/// to those fields is lock-protected, and process, disk, socket, notification,
/// and subscription-close work runs only after releasing the lock.
final class CmuxPluginRuntime: @unchecked Sendable {
    static let snapshotDidChangeNotification = Notification.Name.cmuxPluginManagementDidChange

    let registry: CmuxPluginRegistry
    private let processSupervisor: CmuxPluginProcessSupervisor
    /// Pure lineage resolution lives in the package core; this app-owned
    /// runtime supplies only the Darwin parent-process lookup seam.
    let processAuthorizationResolver: CmuxPluginProcessAuthorizationResolver
    // Internal so feature-specific extensions can share the synchronous
    // projection boundary. Package actors remain authoritative for manifests,
    // grants, tokens, and persistence.
    let lock = NSLock()
    var snapshot = CmuxPluginRegistrySnapshot(plugins: [], failures: [])
    var sessionTokens: [String: String] = [:]
    var processAuthorizations: [pid_t: CmuxPluginProcessAuthorization] = [:]
    var processAuthorizationIdentities: [pid_t: CmuxPluginProcessIdentity] = [:]
    var revokedPluginProcessGroups: [pid_t: Int64] = [:]
    var subscriptionsByPluginID: [String: [UUID: CmuxEventSubscription]] = [:]
    var actionSubscriptionIDsByPluginID: [String: Set<UUID>] = [:]
    private var pluginErrors: [String: String] = [:]
    private var snapshotGeneration: UInt64 = 0
    var pluginShortcutStore: CmuxPluginShortcutStore?
    var routablePluginShortcuts: [String: StoredShortcut] = [:]
    var routablePluginShortcutFirstIndex: [ShortcutStroke: [String]] = [:]
    var routablePluginShortcutSecondIndex: [ShortcutStroke: [String]] = [:]
    var configuredCmuxShortcutBindings: [String: StoredShortcut] = [:]
    private var hasStarted = false
    private var pluginDirectoryWatcher: RecursivePathWatcher?
    private var pluginDirectoryWatchTask: Task<Void, Never>?
    private var pluginPermissionWatcher: FileWatcher?
    private var pluginPermissionWatchTask: Task<Void, Never>?
    var pluginReloadContinuation: AsyncStream<Void>.Continuation?
    private var pluginReloadTask: Task<Void, Never>?
    private var socketListenerObserver: NSObjectProtocol?
    private var shortcutSettingsObserver: NSObjectProtocol?
    var registryUpdateTail: Task<Void, Never>?
    private var processReconciliationTask: Task<Void, Never>?
    var isStopping = false

    @MainActor
    init(
        registry: CmuxPluginRegistry = CmuxPluginRegistry(),
        processSupervisor: CmuxPluginProcessSupervisor? = nil
    ) {
        self.registry = registry
        // Construct the main-actor-owned supervisor inside this initializer's
        // isolation domain. A default argument is evaluated by the caller and
        // cannot invoke a main-actor initializer safely.
        self.processSupervisor = processSupervisor ?? CmuxPluginProcessSupervisor()
        self.processAuthorizationResolver = CmuxPluginProcessAuthorizationResolver(
            parentProcessLookup: Self.parentProcessLookup
        )
        socketListenerObserver = nil
        shortcutSettingsObserver = nil
        pluginDirectoryWatcher = nil
        pluginDirectoryWatchTask = nil
        pluginPermissionWatcher = nil
        pluginPermissionWatchTask = nil
        pluginReloadContinuation = nil
        pluginReloadTask = nil
        registryUpdateTail = nil
        processReconciliationTask = nil
        socketListenerObserver = NotificationCenter.default.addObserver(
            forName: .socketListenerDidStart,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let path = notification.userInfo?["path"] as? String,
                  !path.isEmpty else { return }
            self?.reconcileCurrentProcesses(socketPath: path)
        }
        shortcutSettingsObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadPluginShortcutsFromDisk()
        }
    }

    /// Keeps supervised descendants on the plugin-only socket surface even
    /// while a revoked process is still exiting.
    static func socketPeerPolicy(
        processAuthorization: CmuxPluginProcessAuthorization?,
        isEventStreamRequest: Bool
    ) -> CmuxPluginSocketPeerPolicy {
        switch processAuthorization {
        case .some(.revoked):
            return .denied
        case .some(.active(_)):
            return isEventStreamRequest ? .pluginEventStream : .denied
        case .none:
            return .standard
        }
    }

    deinit {
        if let socketListenerObserver {
            NotificationCenter.default.removeObserver(socketListenerObserver)
        }
        if let shortcutSettingsObserver {
            NotificationCenter.default.removeObserver(shortcutSettingsObserver)
        }
        pluginDirectoryWatchTask?.cancel()
        pluginPermissionWatchTask?.cancel()
        pluginReloadContinuation?.finish()
        pluginReloadTask?.cancel()
        if let pluginDirectoryWatcher {
            Task { await pluginDirectoryWatcher.stop() }
        }
        if let pluginPermissionWatcher {
            Task { await pluginPermissionWatcher.stop() }
        }
    }

    /// Installs the app's shared JSON settings repository before plugin UI or
    /// key-event routing starts. The composition root owns the concrete store;
    /// the runtime only keeps its injected repository and projection.
    @MainActor
    func configure(jsonStore: JSONConfigStore) {
        lock.lock()
        if pluginShortcutStore == nil {
            pluginShortcutStore = CmuxPluginShortcutStore(
                jsonStore: jsonStore,
                onChange: { [weak self] in
                    guard let self else { return }
                    self.refreshRoutablePluginShortcuts()
                    NotificationCenter.default.post(
                        name: .cmuxPluginShortcutsDidChange,
                        object: nil
                    )
                }
            )
        }
        lock.unlock()
        refreshRoutablePluginShortcuts()
    }

    /// Starts the initial scan once per app process.
    func start() {
        lock.lock()
        guard !hasStarted else {
            lock.unlock()
            return
        }
        hasStarted = true
        lock.unlock()
        let watcher = RecursivePathWatcher(
            paths: [CmuxPluginDirectoryLoader.defaultDirectoryURL.path],
            throttleInterval: .milliseconds(250)
        )
        let (reloadEvents, reloadContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let reloadTask = Task { @MainActor [weak self] in
            for await _ in reloadEvents {
                guard let self, !Task.isCancelled else { return }
                await self.performPluginReload()
            }
        }
        let permissionWatcher = CmuxPluginPermissionStore.defaultStorageURL.map {
            FileWatcher(path: $0.path, throttle: .milliseconds(250))
        }
        lock.lock()
        pluginDirectoryWatcher = watcher
        pluginPermissionWatcher = permissionWatcher
        pluginReloadContinuation = reloadContinuation
        pluginReloadTask = reloadTask
        if let watcher {
            pluginDirectoryWatchTask = Task { @MainActor [weak self, watcher] in
                for await _ in watcher.events {
                    guard let self, !Task.isCancelled else { return }
                    self.reload()
                }
            }
        }
        if let permissionWatcher {
            pluginPermissionWatchTask = Task { @MainActor [weak self, permissionWatcher] in
                for await _ in permissionWatcher.events {
                    guard let self, !Task.isCancelled else { return }
                    self.reload()
                }
            }
        }
        lock.unlock()
        reload()
    }

    /// Current UI/diagnostic snapshot.
    func currentSnapshot() -> CmuxPluginRegistrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Returns a launch, process-health, or management failure for a plugin.
    /// Manifest failures remain in the package snapshot.
    func pluginError(for pluginID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pluginErrors[pluginID]
    }

    /// Resolves an enabled palette action by its namespaced id.
    func action(forNamespacedID id: String) -> (pluginID: String, action: CmuxExtensionAction)? {
        lock.lock()
        defer { lock.unlock() }
        for descriptor in snapshot.plugins where descriptor.isEnabled {
            let pluginID = descriptor.plugin.manifest.id
            guard actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == false else { continue }
            for action in descriptor.plugin.manifest.actions
                where CmuxPluginRegistry.namespacedActionID(pluginID: pluginID, actionID: action.id) == id
                    && descriptor.permissions.allowsAction(action.id) {
                return (pluginID, action)
            }
        }
        return nil
    }

    /// Publishes a palette action invocation through the existing event bus.
    func invokeAction(pluginID: String, actionID: String) -> Bool {
        lock.lock()
        guard let descriptor = snapshot.plugins.first(where: { $0.plugin.manifest.id == pluginID }),
              descriptor.isEnabled,
              descriptor.permissions.allowsAction(actionID),
              actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == false else {
            lock.unlock()
            return false
        }
        lock.unlock()

        let invocation = CmuxPluginActionInvocation(
            pluginID: pluginID,
            actionID: actionID,
            occurredAt: Self.isoTimestamp(Date())
        )
        let payload: [String: Any] = [
            "plugin_id": invocation.pluginID,
            "action_id": invocation.actionID,
            "invocation_id": invocation.invocationID,
            "occurred_at": invocation.occurredAt,
            "context": invocation.context.mapValues(\.foundationValue),
        ]
        CmuxEventBus.shared.publish(
            name: CmuxPluginActionInvocation.eventName,
            category: "plugin",
            source: "plugin.palette",
            payload: payload
        )
        return true
    }

    func replace(snapshot next: CmuxPluginRegistrySnapshot, tokens: [String: String]) {
        lock.lock()
        guard !isStopping else {
            lock.unlock()
            return
        }
        let previousByID = Dictionary(snapshot.plugins.map {
            ($0.plugin.manifest.id, $0)
        }, uniquingKeysWith: { _, replacement in replacement })
        let nextByID = Dictionary(next.plugins.map {
            ($0.plugin.manifest.id, $0)
        }, uniquingKeysWith: { _, replacement in replacement })
        let revokedPluginIDs = Set(subscriptionsByPluginID.keys.filter { pluginID in
            guard let previous = previousByID[pluginID],
                  let replacement = nextByID[pluginID] else {
                return true
            }
            return sessionTokens[pluginID] != tokens[pluginID]
                || previous.permissions != replacement.permissions
                || previous.plugin.manifestFingerprint != replacement.plugin.manifestFingerprint
        })
        let revokedSubscriptions = revokedPluginIDs.flatMap { pluginID -> [CmuxEventSubscription] in
            actionSubscriptionIDsByPluginID[pluginID] = nil
            guard let subscriptions = subscriptionsByPluginID.removeValue(forKey: pluginID) else {
                return []
            }
            return Array(subscriptions.values)
        }
        snapshot = next
        sessionTokens = tokens
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        let validIDs = Set(next.plugins.map { $0.plugin.manifest.id })
        pluginErrors = pluginErrors.filter { validIDs.contains($0.key) }
        routablePluginShortcuts.removeAll()
        routablePluginShortcutFirstIndex.removeAll()
        routablePluginShortcutSecondIndex.removeAll()
        lock.unlock()
        revokedSubscriptions.forEach { $0.close() }
        refreshRoutablePluginShortcuts()
        reconcileProcesses(
            snapshot: next,
            tokens: tokens,
            socketPath: nil,
            generation: generation
        )
        postSnapshotNotifications()
    }

    /// Reconciles enabled children after the listener announces a usable path.
    /// Initial plugin discovery can race app startup, so launch is gated on the
    /// real listener signal instead of a timing delay or a retry loop.
    private func reconcileCurrentProcesses(socketPath: String) {
        lock.lock()
        let currentSnapshot = snapshot
        let currentTokens = sessionTokens
        let generation = snapshotGeneration
        lock.unlock()
        reconcileProcesses(
            snapshot: currentSnapshot,
            tokens: currentTokens,
            socketPath: socketPath,
            generation: generation
        )
    }

    private func reconcileProcesses(
        snapshot next: CmuxPluginRegistrySnapshot,
        tokens: [String: String],
        socketPath: String?,
        generation: UInt64
    ) {
        lock.lock()
        processReconciliationTask?.cancel()
        processReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard processReconciliationIsAllowed(generation: generation) else { return }
            let resolvedSocketPath = socketPath ?? TerminalController.shared.activeSocketPath(
                preferredPath: SocketControlSettings.socketPath()
            )
            let socketServer = TerminalController.shared.socketServer
            let probeInput = socketServer.listenerHealthProbeInput(
                expectedSocketPath: resolvedSocketPath
            )
            let transport = socketServer.transport
            let listenerReady = await Task.detached(priority: .utility) {
                probeInput.resolve(using: transport).isHealthy
            }.value
            guard !Task.isCancelled else { return }
            guard processReconciliationIsAllowed(generation: generation) else { return }
            await processSupervisor.reconcile(
                snapshot: next,
                sessionTokens: tokens,
                socketPath: resolvedSocketPath,
                generation: generation,
                allowLaunch: listenerReady,
                runtime: self,
                reportError: { [weak self] pluginID, error in
                    self?.recordPluginError(error, for: pluginID)
                }
            )
        }
        lock.unlock()
    }

    func processReconciliationIsAllowed(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isStopping && snapshotGeneration == generation
    }

    private func postSnapshotNotifications() {
        // SwiftUI settings and command-palette state are main-actor owned. The
        // registry reload itself runs off-main, so deliver the notification on
        // the main actor rather than relying on NotificationCenter's posting
        // thread as an accidental scheduler.
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.snapshotDidChangeNotification, object: nil)
            NotificationCenter.default.post(
                name: .cmuxPluginShortcutsDidChange,
                object: nil
            )
        }
    }

    /// Reprojects palette and keyboard contributions after a plugin registers
    /// or removes its private action receiver. The live subscription is the
    /// readiness signal; no launch delay or polling loop is involved.
    func actionReadinessDidChange() {
        Task { @MainActor in
            self.refreshRoutablePluginShortcuts()
            NotificationCenter.default.post(name: Self.snapshotDidChangeNotification, object: nil)
            NotificationCenter.default.post(
                name: .cmuxPluginShortcutsDidChange,
                object: nil
            )
        }
    }

    /// Whether an enabled plugin currently owns a live action event receiver.
    func canReceiveActionInvocations(pluginID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == false
    }

    func recordPluginError(_ error: String?, for pluginID: String) {
        lock.lock()
        guard !isStopping else {
            lock.unlock()
            return
        }
        if let error {
            pluginErrors[pluginID] = error
        } else {
            pluginErrors.removeValue(forKey: pluginID)
        }
        lock.unlock()
        postSnapshotNotifications()
    }

    /// Stops all plugin children before the app's socket and terminal teardown.
    @MainActor
    func stop() {
        lock.lock()
        isStopping = true
        registryUpdateTail?.cancel()
        processReconciliationTask?.cancel()
        pluginDirectoryWatchTask?.cancel()
        pluginDirectoryWatchTask = nil
        pluginPermissionWatchTask?.cancel()
        pluginPermissionWatchTask = nil
        pluginReloadContinuation?.finish()
        pluginReloadContinuation = nil
        pluginReloadTask?.cancel()
        pluginReloadTask = nil
        let pluginDirectoryWatcher = self.pluginDirectoryWatcher
        self.pluginDirectoryWatcher = nil
        let pluginPermissionWatcher = self.pluginPermissionWatcher
        self.pluginPermissionWatcher = nil
        let subscriptions = subscriptionsByPluginID.values.flatMap(\.values)
        subscriptionsByPluginID.removeAll()
        actionSubscriptionIDsByPluginID.removeAll()
        for processID in Array(processAuthorizations.keys) {
            processAuthorizations[processID] = .revoked
        }
        sessionTokens.removeAll()
        routablePluginShortcuts.removeAll()
        routablePluginShortcutFirstIndex.removeAll()
        routablePluginShortcutSecondIndex.removeAll()
        pluginErrors.removeAll()
        lock.unlock()
        if let pluginDirectoryWatcher {
            Task { await pluginDirectoryWatcher.stop() }
        }
        if let pluginPermissionWatcher {
            Task { await pluginPermissionWatcher.stop() }
        }
        processSupervisor.stopAll(runtime: self)
        subscriptions.forEach { $0.close() }
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

}
