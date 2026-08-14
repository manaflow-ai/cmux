import CmuxExtensionKit
import CmuxSettings
import CmuxSettingsUI
import Darwin
import Foundation

/// A synchronous authorization projection for the socket worker.
enum CmuxPluginSocketAuthorization: Sendable, Equatable {
    case allowed(Set<String>)
    case denied(String)
}

/// Authorization state retained for a supervised plugin process lineage.
///
/// Revoked roots remain classified until their process termination callback
/// arrives. This prevents a disabled child that is still exiting from falling
/// back to the control socket's broader "cmux descendant" allow-list.
enum CmuxPluginProcessAuthorization: Sendable, Equatable {
    case active(pluginID: String)
    case revoked
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
    static let shared = CmuxPluginRuntime()

    static let snapshotDidChangeNotification = PluginManagementSettings.didChangeNotification

    let registry: CmuxPluginRegistry
    // Internal so feature-specific extensions can share the synchronous
    // projection boundary. Package actors remain authoritative for manifests,
    // grants, tokens, and persistence.
    let lock = NSLock()
    private var snapshot = CmuxPluginRegistrySnapshot(plugins: [], failures: [])
    private var sessionTokens: [String: String] = [:]
    var processAuthorizations: [pid_t: CmuxPluginProcessAuthorization] = [:]
    var subscriptionsByPluginID: [String: [UUID: CmuxEventSubscription]] = [:]
    var actionSubscriptionIDsByPluginID: [String: Set<UUID>] = [:]
    private var pluginErrors: [String: String] = [:]
    private var snapshotGeneration: UInt64 = 0
    var pluginShortcutStore: CmuxPluginShortcutStore?
    var routablePluginShortcuts: [String: StoredShortcut] = [:]
    private var hasStarted = false
    private var socketListenerObserver: NSObjectProtocol?
    private var shortcutSettingsObserver: NSObjectProtocol?
    var registryUpdateTail: Task<Void, Never>?
    var isStopping = false

    private init() {
        registry = CmuxPluginRegistry()
        socketListenerObserver = nil
        shortcutSettingsObserver = nil
        registryUpdateTail = nil
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
    }

    /// Installs the app's shared JSON settings repository before plugin UI or
    /// key-event routing starts. The composition root owns the concrete store;
    /// the runtime only keeps its injected repository and projection.
    func configure(jsonStore: JSONConfigStore) {
        lock.lock()
        if pluginShortcutStore == nil {
            pluginShortcutStore = CmuxPluginShortcutStore(jsonStore: jsonStore)
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

    /// Checks a plugin-tagged `events.stream` request on the socket worker.
    func authorizeSubscription(
        pluginID: String,
        token: String,
        requestedNames: Set<String>,
        peerProcessID: pid_t? = nil
    ) -> CmuxPluginSocketAuthorization {
        lock.lock()
        defer { lock.unlock() }
        guard let peerProcessID,
              Self.processAuthorization(
                  for: peerProcessID,
                  in: processAuthorizations
              ) == .active(pluginID: pluginID) else {
            return .denied("plugin identity does not match a supervised process")
        }
        guard let descriptor = snapshot.plugins.first(where: { $0.plugin.manifest.id == pluginID }) else {
            return .denied("unknown plugin")
        }
        guard descriptor.isEnabled, sessionTokens[pluginID] == token else {
            return .denied(descriptor.isEnabled ? "invalid plugin session token" : "plugin is disabled")
        }
        let allowedNames = CmuxPluginSubscriptionPolicy(
            pluginID: pluginID,
            permissions: descriptor.permissions
        ).allowedEventNames
        guard !allowedNames.isEmpty else {
            return .denied("plugin has no approved event or action subscriptions")
        }
        if requestedNames.isEmpty {
            return .allowed(Self.canonicalEventNames(allowedNames))
        }
        let denied = requestedNames.subtracting(allowedNames)
        guard denied.isEmpty else {
            return .denied("event scope not granted: \(denied.sorted().joined(separator: ", "))")
        }
        return .allowed(Self.canonicalEventNames(requestedNames))
    }

    /// Registers a live stream under the same lock as the token projection.
    /// This closes the authorization-to-subscription race: a disable or grant
    /// change either wins first and rejects registration, or wins second and
    /// closes the newly registered stream.
    func registerSubscription(
        _ subscription: CmuxEventSubscription,
        pluginID: String,
        token: String,
        peerProcessID: pid_t?
    ) -> Bool {
        lock.lock()
        guard let peerProcessID,
              Self.processAuthorization(
                  for: peerProcessID,
                  in: processAuthorizations
              ) == .active(pluginID: pluginID),
              sessionTokens[pluginID] == token,
              snapshot.plugins.contains(where: {
                  $0.plugin.manifest.id == pluginID && $0.isEnabled
              }) else {
            lock.unlock()
            return false
        }
        subscriptionsByPluginID[pluginID, default: [:]][subscription.id] = subscription
        let receivesActions = subscription.names.contains(CmuxPluginActionInvocation.eventName)
        let becameActionReady: Bool
        if receivesActions {
            let wasReady = actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == false
            actionSubscriptionIDsByPluginID[pluginID, default: []].insert(subscription.id)
            becameActionReady = !wasReady
        } else {
            becameActionReady = false
        }
        lock.unlock()
        if becameActionReady {
            actionReadinessDidChange()
        }
        return true
    }

    /// Removes a completed stream from the revocation registry.
    func unregisterSubscription(_ subscription: CmuxEventSubscription, pluginID: String) {
        lock.lock()
        subscriptionsByPluginID[pluginID]?[subscription.id] = nil
        if subscriptionsByPluginID[pluginID]?.isEmpty == true {
            subscriptionsByPluginID[pluginID] = nil
        }
        let wasActionReady = actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == false
        actionSubscriptionIDsByPluginID[pluginID]?.remove(subscription.id)
        if actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == true {
            actionSubscriptionIDsByPluginID[pluginID] = nil
        }
        let becameActionUnavailable = wasActionReady
            && actionSubscriptionIDsByPluginID[pluginID] == nil
        lock.unlock()
        if becameActionUnavailable {
            actionReadinessDidChange()
        }
    }

    /// Synchronous generation check used immediately before socket writes.
    func subscriptionIsCurrent(pluginID: String, token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionTokens[pluginID] == token
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
        let previousByID = Dictionary(uniqueKeysWithValues: snapshot.plugins.map {
            ($0.plugin.manifest.id, $0)
        })
        let nextByID = Dictionary(uniqueKeysWithValues: next.plugins.map {
            ($0.plugin.manifest.id, $0)
        })
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
        lock.unlock()
        revokedSubscriptions.forEach { $0.close() }
        refreshRoutablePluginShortcuts()
        let preferredSocketPath = SocketControlSettings.socketPath()
        let activeSocketPath = TerminalController.shared.activeSocketPath(
            preferredPath: preferredSocketPath
        )
        reconcileProcesses(
            snapshot: next,
            tokens: tokens,
            socketPath: activeSocketPath,
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
        socketPath: String,
        generation: UInt64
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard processReconciliationIsAllowed(generation: generation) else { return }
            let listenerReady = TerminalController.shared
                .socketListenerHealth(expectedSocketPath: socketPath)
                .isHealthy
            CmuxPluginProcessSupervisor.shared.reconcile(
                snapshot: next,
                sessionTokens: tokens,
                socketPath: socketPath,
                allowLaunch: listenerReady,
                reportError: { pluginID, error in
                    CmuxPluginRuntime.shared.recordPluginError(error, for: pluginID)
                }
            )
        }
    }

    private func processReconciliationIsAllowed(generation: UInt64) -> Bool {
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
                name: PluginShortcutSettings.didChangeNotification,
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
                name: PluginShortcutSettings.didChangeNotification,
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
        let subscriptions = subscriptionsByPluginID.values.flatMap(\.values)
        subscriptionsByPluginID.removeAll()
        actionSubscriptionIDsByPluginID.removeAll()
        for processID in Array(processAuthorizations.keys) {
            processAuthorizations[processID] = .revoked
        }
        sessionTokens.removeAll()
        routablePluginShortcuts.removeAll()
        pluginErrors.removeAll()
        lock.unlock()
        CmuxPluginProcessSupervisor.shared.stopAll()
        subscriptions.forEach { $0.close() }
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func canonicalEventNames(_ names: Set<String>) -> Set<String> {
        Set(names.compactMap { name in
            if name == CmuxPluginActionInvocation.eventName { return name }
            return CmuxExtensionEvent.canonicalName(forWireName: name)
        })
    }

}
