import Foundation

/// A plugin plus its current effective permissions, suitable for Settings or
/// command-palette composition.
public struct CmuxPluginDescriptor: Equatable, Sendable {
    /// The validated plugin on disk.
    public let plugin: CmuxLoadedPlugin
    /// The current user-approved capability intersection.
    public let permissions: CmuxPluginPermissions
    /// Whether the current plugin artifact fingerprint has an explicit stored grant.
    public let isApproved: Bool
    /// The load-time error is kept outside descriptors in the report.
    public var isEnabled: Bool {
        permissions.enabled
    }

    /// Creates a descriptor.
    public init(plugin: CmuxLoadedPlugin, permissions: CmuxPluginPermissions, isApproved: Bool = false) {
        self.plugin = plugin
        self.permissions = permissions
        self.isApproved = isApproved
    }
}

/// A snapshot of the plugin registry used by UI and host adapters.
public struct CmuxPluginRegistrySnapshot: Equatable, Sendable {
    /// Valid, discovered plugins.
    public let plugins: [CmuxPluginDescriptor]
    /// Load errors retained for diagnostics.
    public let failures: [CmuxPluginLoadFailure]
    /// A fail-closed grant-file load failure retained for Settings diagnostics.
    public let permissionStoreLoadFailure: CmuxPluginPermissionStoreLoadFailure?

    /// Creates a snapshot.
    public init(
        plugins: [CmuxPluginDescriptor],
        failures: [CmuxPluginLoadFailure],
        permissionStoreLoadFailure: CmuxPluginPermissionStoreLoadFailure? = nil
    ) {
        self.plugins = plugins
        self.failures = failures
        self.permissionStoreLoadFailure = permissionStoreLoadFailure
    }
}

/// Errors returned when a plugin attempts to use the host protocol.
public enum CmuxPluginAuthorizationError: Error, Equatable, Sendable {
    /// No currently loaded plugin has the requested identifier.
    case unknownPlugin
    /// The current plugin artifact fingerprint has not been approved.
    case notApproved
    /// The plugin is disabled or has no active session.
    case disabled
    /// The supplied in-memory session token is stale or invalid.
    case invalidToken
    /// The requested lifecycle event is outside the effective grant.
    case eventNotGranted(String)
    /// The requested plugin-local action is outside the effective grant.
    case actionNotGranted(String)
}

/// Actor that joins manifest discovery, user grants, and protocol authorization.
///
/// Keeping these decisions in one actor prevents the command palette, Settings,
/// and socket event stream from maintaining divergent permission copies.
public actor CmuxPluginRegistry {
    private let loader: CmuxPluginDirectoryLoader
    private let permissionStore: CmuxPluginPermissionStore
    private var report = CmuxPluginLoadReport(plugins: [], failures: [])
    private var permissionsByID: [String: CmuxPluginPermissions] = [:]
    private var approvalByID: [String: Bool] = [:]
    private var tokensByID: [String: String] = [:]
    private var tokenFingerprintsByID: [String: String] = [:]
    private var reloadGeneration: UInt64 = 0
    private var permissionStoreLoadFailure: CmuxPluginPermissionStoreLoadFailure?

    /// Creates a registry from a loader and permission store.
    public init(
        loader: CmuxPluginDirectoryLoader = CmuxPluginDirectoryLoader(),
        permissionStore: CmuxPluginPermissionStore = CmuxPluginPermissionStore()
    ) {
        self.loader = loader
        self.permissionStore = permissionStore
    }

    /// Reloads manifests and recomputes all effective grants.
    @discardableResult
    public func reload() async -> CmuxPluginRegistrySnapshot {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let loadedReport = await loader.load()
        return await reload(loadedReport: loadedReport, generation: generation)
    }

    /// Reloads only the plugin directories named by a path-aware file event.
    @discardableResult
    public func reload(affectedPluginIDs: Set<String>) async -> CmuxPluginRegistrySnapshot {
        guard !affectedPluginIDs.isEmpty else { return await reload() }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let partialReport = await loader.load(only: affectedPluginIDs)
        let mergedReport = mergedReport(
            replacing: affectedPluginIDs,
            with: partialReport
        )
        return await reload(loadedReport: mergedReport, generation: generation)
    }

    private func reload(
        loadedReport: CmuxPluginLoadReport,
        generation: UInt64
    ) async -> CmuxPluginRegistrySnapshot {
        let previousTokens = tokensByID
        let previousTokenFingerprints = tokenFingerprintsByID
        let previousPermissions = permissionsByID
        let loadedPermissionStoreFailure = await permissionStore.storageLoadFailure()
        var nextPermissions: [String: CmuxPluginPermissions] = [:]
        var nextApprovals: [String: Bool] = [:]
        var nextTokens: [String: String] = [:]
        var nextTokenFingerprints: [String: String] = [:]
        var actionOwners: [String: (pluginID: String, actionID: String)] = [:]
        var ambiguousActionsByPluginID: [String: Set<String>] = [:]
        for plugin in loadedReport.plugins {
            for action in plugin.manifest.actions {
                let namespacedID = Self.namespacedActionID(
                    pluginID: plugin.manifest.id,
                    actionID: action.id
                )
                if let owner = actionOwners[namespacedID], owner.pluginID != plugin.manifest.id {
                    ambiguousActionsByPluginID[owner.pluginID, default: []].insert(owner.actionID)
                    ambiguousActionsByPluginID[plugin.manifest.id, default: []].insert(action.id)
                } else {
                    actionOwners[namespacedID] = (plugin.manifest.id, action.id)
                }
            }
        }
        for plugin in loadedReport.plugins {
            let grant = await permissionStore.grant(for: plugin)
            var permissions = grant.effectivePermissions(for: plugin)
            // Dot-joined IDs are retained for wire compatibility, so disable
            // only colliding declarations rather than allowing one plugin to
            // shadow another in the palette or shortcut router.
            permissions.actions.subtract(
                ambiguousActionsByPluginID[plugin.manifest.id] ?? []
            )
            nextPermissions[plugin.manifest.id] = permissions
            nextApprovals[plugin.manifest.id] = grant.pluginID == plugin.manifest.id
                && grant.manifestFingerprint == plugin.manifestFingerprint
                && grant.approved
            if permissions.enabled {
                let pluginID = plugin.manifest.id
                if let previousToken = previousTokens[pluginID],
                   previousTokenFingerprints[pluginID] == plugin.manifestFingerprint,
                   previousPermissions[pluginID] == permissions {
                    nextTokens[pluginID] = previousToken
                } else {
                    nextTokens[pluginID] = UUID().uuidString
                }
                nextTokenFingerprints[pluginID] = plugin.manifestFingerprint
            }
        }
        // Actor methods are reentrant at each loader/store await. A newer
        // reload owns the commit if calls overlap; an older scan must never
        // replace its manifest, grant, or token projection afterward.
        guard generation == reloadGeneration else { return snapshot() }
        report = loadedReport
        permissionStoreLoadFailure = loadedPermissionStoreFailure
        tokensByID = nextTokens
        tokenFingerprintsByID = nextTokenFingerprints
        permissionsByID = nextPermissions
        approvalByID = nextApprovals
        return snapshot()
    }

    private func mergedReport(
        replacing pluginIDs: Set<String>,
        with partialReport: CmuxPluginLoadReport
    ) -> CmuxPluginLoadReport {
        let retainedPlugins = report.plugins.filter {
            !pluginIDs.contains($0.manifest.id)
                && !pluginIDs.contains($0.directoryURL.lastPathComponent)
        }
        let retainedFailures = report.failures.filter {
            !pluginIDs.contains($0.directoryURL.lastPathComponent)
        }
        return CmuxPluginLoadReport(
            plugins: (retainedPlugins + partialReport.plugins)
                .sorted { $0.manifest.id < $1.manifest.id },
            failures: (retainedFailures + partialReport.failures)
                .sorted { $0.directoryURL.path < $1.directoryURL.path }
        )
    }

    /// Returns the current registry snapshot without rescanning.
    public func snapshot() -> CmuxPluginRegistrySnapshot {
        CmuxPluginRegistrySnapshot(
            plugins: report.plugins.compactMap { plugin in
                guard let permissions = permissionsByID[plugin.manifest.id] else { return nil }
                return CmuxPluginDescriptor(
                    plugin: plugin,
                    permissions: permissions,
                    isApproved: approvalByID[plugin.manifest.id] ?? false
                )
            },
            failures: report.failures,
            permissionStoreLoadFailure: permissionStoreLoadFailure
        )
    }

    /// Explicitly approves all declarations in Settings and reloads grants.
    public func approveAll(pluginID: String) async throws -> CmuxPluginRegistrySnapshot {
        let plugin = try loadedPlugin(pluginID)
        try await permissionStore.approveAll(for: plugin)
        return await reload()
    }

    /// Enables or disables one plugin while retaining its approved scopes.
    public func setEnabled(_ enabled: Bool, pluginID: String) async throws -> CmuxPluginRegistrySnapshot {
        let plugin = try loadedPlugin(pluginID)
        try await permissionStore.setEnabled(enabled, for: plugin)
        return await reload()
    }

    /// Returns a process session token for an enabled plugin. Tokens are
    /// memory-only and rotate when a plugin is disabled or its manifest changes.
    public func sessionToken(pluginID: String) throws -> String {
        guard let permissions = permissionsByID[pluginID] else {
            throw CmuxPluginAuthorizationError.unknownPlugin
        }
        guard permissions.enabled, let token = tokensByID[pluginID] else {
            throw CmuxPluginAuthorizationError.disabled
        }
        return token
    }

    /// Authorizes an event-stream request and returns the intersection of the
    /// requested names with the plugin's approved event names.
    public func authorizeSubscription(
        pluginID: String,
        token: String,
        requestedNames: Set<String>
    ) throws -> Set<String> {
        guard let permissions = permissionsByID[pluginID] else {
            throw CmuxPluginAuthorizationError.unknownPlugin
        }
        guard permissions.enabled else {
            throw CmuxPluginAuthorizationError.disabled
        }
        guard let expectedToken = tokensByID[pluginID],
              Self.constantTimeEquals(expectedToken, token) else {
            throw CmuxPluginAuthorizationError.invalidToken
        }
        let allowedNames = CmuxPluginSubscriptionPolicy(
            pluginID: pluginID,
            permissions: permissions
        ).allowedEventNames
        let canonicalAllowedNames = Set(allowedNames.compactMap(Self.canonicalEventName))
        guard requestedNames.isEmpty else {
            let unresolved = requestedNames.filter { Self.canonicalEventName($0) == nil }
            guard unresolved.isEmpty else {
                throw CmuxPluginAuthorizationError.eventNotGranted(
                    unresolved.sorted().joined(separator: ",")
                )
            }
            let canonicalRequestedNames = Set(requestedNames.compactMap(Self.canonicalEventName))
            let denied = canonicalRequestedNames.subtracting(canonicalAllowedNames)
            guard denied.isEmpty else {
                throw CmuxPluginAuthorizationError.eventNotGranted(denied.sorted().joined(separator: ","))
            }
            return canonicalRequestedNames
        }
        return canonicalAllowedNames
    }

    /// Authorizes a plugin palette action invocation.
    public func authorizeAction(pluginID: String, actionID: String) throws {
        guard let permissions = permissionsByID[pluginID] else {
            throw CmuxPluginAuthorizationError.unknownPlugin
        }
        guard permissions.enabled else {
            throw CmuxPluginAuthorizationError.disabled
        }
        guard permissions.allowsAction(actionID) else {
            throw CmuxPluginAuthorizationError.actionNotGranted(actionID)
        }
    }

    /// Resolves a namespaced palette action to its plugin and declaration.
    public func action(forNamespacedID id: String) -> (plugin: CmuxLoadedPlugin, action: CmuxExtensionAction)? {
        // Plugin identifiers are reverse-DNS values and therefore contain
        // dots themselves. Do not split the wire id at the first (or last)
        // dot: resolving against the loaded declarations is both unambiguous
        // and keeps the namespace stable for every valid manifest id.
        for plugin in report.plugins {
            let pluginID = plugin.manifest.id
            for action in plugin.manifest.actions {
                guard Self.namespacedActionID(pluginID: pluginID, actionID: action.id) == id,
                      permissionsByID[pluginID]?.allowsAction(action.id) == true else {
                    continue
                }
                return (plugin, action)
            }
        }
        return nil
    }

    /// Returns the namespaced command identifier for one declaration.
    public static func namespacedActionID(pluginID: String, actionID: String) -> String {
        CmuxExtensionActionID(pluginID: pluginID, actionID: actionID).rawValue
    }

    private func loadedPlugin(_ pluginID: String) throws -> CmuxLoadedPlugin {
        guard let plugin = report.plugins.first(where: { $0.manifest.id == pluginID }) else {
            throw CmuxPluginAuthorizationError.unknownPlugin
        }
        return plugin
    }

    private static func canonicalEventName(_ name: String) -> String? {
        if name == CmuxPluginActionInvocation.eventName { return name }
        return CmuxExtensionEvent.canonicalName(forWireName: name)
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

}
