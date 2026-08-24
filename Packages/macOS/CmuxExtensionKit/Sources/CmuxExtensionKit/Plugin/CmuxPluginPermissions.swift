import Foundation

/// The effective, user-approved capabilities of one plugin.
public struct CmuxPluginPermissions: Codable, Equatable, Sendable {
    /// Whether the plugin is enabled. This remains distinct from an empty
    /// scope set so a deliberately enabled, no-op plugin is represented
    /// correctly in Settings.
    public var enabled: Bool
    /// Approved legacy sidebar read scopes.
    public var readScopes: Set<CmuxExtensionScope>
    /// Approved legacy sidebar action scopes.
    public var actionScopes: Set<CmuxExtensionActionScope>
    /// Approved process-backed plugin scopes.
    public var pluginScopes: Set<CmuxExtensionPluginScope>
    /// Event declarations approved for delivery.
    public var events: Set<CmuxExtensionEvent>
    /// Action declarations approved for invocation.
    public var actions: Set<String>

    /// A fail-closed permission set.
    public static let none = Self(
        enabled: false,
        readScopes: [],
        actionScopes: [],
        pluginScopes: [],
        events: [],
        actions: []
    )

    /// Creates an effective permission set.
    public init(
        enabled: Bool = false,
        readScopes: Set<CmuxExtensionScope> = [],
        actionScopes: Set<CmuxExtensionActionScope> = [],
        pluginScopes: Set<CmuxExtensionPluginScope> = [],
        events: Set<CmuxExtensionEvent> = [],
        actions: Set<String> = []
    ) {
        self.enabled = enabled
        self.readScopes = readScopes
        self.actionScopes = actionScopes
        self.pluginScopes = pluginScopes
        self.events = events
        self.actions = actions
    }

    /// Whether this grant permits the event.
    public func allows(_ event: CmuxExtensionEvent) -> Bool {
        enabled && pluginScopes.contains(.eventHooks) && events.contains(event)
    }

    /// Whether this grant permits the plugin-local action id.
    public func allowsAction(_ actionID: String) -> Bool {
        enabled && pluginScopes.contains(.paletteActions) && actions.contains(actionID)
    }
}

/// Persisted grant record for one plugin.
public struct CmuxPluginGrant: Codable, Equatable, Sendable {
    /// Plugin identity this grant belongs to.
    public var pluginID: String
    /// Plugin artifact fingerprint at the time of approval.
    public var manifestFingerprint: String
    /// Whether the plugin is enabled.
    public var enabled: Bool
    /// Whether the user has explicitly approved this plugin artifact fingerprint.
    ///
    /// Approval is intentionally separate from enablement so a user can turn
    /// off an already-reviewed plugin without being shown the first-run
    /// permission review again.
    public var approved: Bool
    /// Approved legacy/sidebar scopes.
    public var readScopes: Set<CmuxExtensionScope>
    /// Approved legacy sidebar action scopes.
    public var actionScopes: Set<CmuxExtensionActionScope>
    /// Approved plugin scope families.
    public var pluginScopes: Set<CmuxExtensionPluginScope>
    /// Approved event declarations.
    public var events: Set<CmuxExtensionEvent>
    /// Approved plugin-local action identifiers.
    public var actions: Set<String>

    /// Creates a grant record.
    public init(
        pluginID: String,
        manifestFingerprint: String,
        enabled: Bool = false,
        approved: Bool = false,
        readScopes: Set<CmuxExtensionScope> = [],
        actionScopes: Set<CmuxExtensionActionScope> = [],
        pluginScopes: Set<CmuxExtensionPluginScope> = [],
        events: Set<CmuxExtensionEvent> = [],
        actions: Set<String> = []
    ) {
        self.pluginID = pluginID
        self.manifestFingerprint = manifestFingerprint
        self.enabled = enabled
        self.approved = approved
        self.readScopes = readScopes
        self.actionScopes = actionScopes
        self.pluginScopes = pluginScopes
        self.events = events
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case pluginID
        case manifestFingerprint
        case enabled
        case approved
        case readScopes
        case actionScopes
        case pluginScopes
        case events
        case actions
    }

    /// Decodes grants written before explicit approval was persisted.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try container.decode(String.self, forKey: .pluginID)
        manifestFingerprint = try container.decode(String.self, forKey: .manifestFingerprint)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        approved = try container.decodeIfPresent(Bool.self, forKey: .approved)
            ?? enabled
        readScopes = try container.decodeIfPresent(Set<CmuxExtensionScope>.self, forKey: .readScopes) ?? []
        actionScopes = try container.decodeIfPresent(Set<CmuxExtensionActionScope>.self, forKey: .actionScopes) ?? []
        pluginScopes = try container.decodeIfPresent(Set<CmuxExtensionPluginScope>.self, forKey: .pluginScopes) ?? []
        events = try container.decodeIfPresent(Set<CmuxExtensionEvent>.self, forKey: .events) ?? []
        actions = try container.decodeIfPresent(Set<String>.self, forKey: .actions) ?? []
    }

    /// Encodes the complete grant schema, including the explicit approval bit.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encode(manifestFingerprint, forKey: .manifestFingerprint)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(approved, forKey: .approved)
        try container.encode(readScopes, forKey: .readScopes)
        try container.encode(actionScopes, forKey: .actionScopes)
        try container.encode(pluginScopes, forKey: .pluginScopes)
        try container.encode(events, forKey: .events)
        try container.encode(actions, forKey: .actions)
    }

    /// Computes the effective permission intersection for a loaded manifest.
    public func effectivePermissions(for plugin: CmuxLoadedPlugin) -> CmuxPluginPermissions {
        guard approved,
              enabled,
              pluginID == plugin.manifest.id,
              manifestFingerprint == plugin.manifestFingerprint else {
            return .none
        }
        let manifest = plugin.manifest
        let requestedEvents = Set(manifest.eventSubscriptions)
        let requestedActions = Set(manifest.actions.map(\.id))
        return CmuxPluginPermissions(
            enabled: true,
            readScopes: Set(manifest.readScopes).intersection(readScopes),
            actionScopes: Set(manifest.actionScopes).intersection(actionScopes),
            pluginScopes: manifest.requestedPluginScopes.intersection(pluginScopes),
            events: requestedEvents.intersection(events),
            actions: requestedActions.intersection(actions)
        )
    }
}

/// Actor-backed persistence for plugin enablement and permission approvals.
///
/// A missing record, an unapproved/disabled record, or an artifact fingerprint
/// mismatch all resolve to ``CmuxPluginPermissions/none``. This makes
/// permission handling fail closed even if a plugin directory is copied over
/// an existing one.
public actor CmuxPluginPermissionStore {
    /// Current schema version for the JSON grant file.
    public static let schemaVersion = 1

    private struct FileEnvelope: Codable {
        var schemaVersion: Int
        var grants: [String: CmuxPluginGrant]
    }

    /// Cheap identity for the on-disk grant source. The store rechecks this
    /// before every read so an external Settings/editor update cannot leave
    /// the actor's projection stale indefinitely.
    private struct FileSignature: Equatable, Sendable {
        let exists: Bool
        let byteCount: Int?
        let modificationDate: Date?
        let fileNumber: UInt64?

        static let missing = Self(
            exists: false,
            byteCount: nil,
            modificationDate: nil,
            fileNumber: nil
        )
    }

    private let storageURL: URL?
    private let fileManager: FileManager
    private var grants: [String: CmuxPluginGrant] = [:]
    private var hasLoaded = false
    private var loadFailure: CmuxPluginPermissionStoreLoadFailure?
    private var loadedFileSignature: FileSignature?

    /// Creates a store. Passing `nil` keeps grants in memory, which is useful
    /// for tests and hosts that provide their own persistence layer.
    public init(
        storageURL: URL? = CmuxPluginPermissionStore.defaultStorageURL,
        fileManager: FileManager = .default
    ) {
        self.storageURL = storageURL?.standardizedFileURL
        self.fileManager = fileManager
        loadedFileSignature = nil
    }

    /// Default grant location under Application Support.
    public static var defaultStorageURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("plugin-grants.json", isDirectory: false)
    }

    /// Returns the raw grant, or a disabled empty grant for a new plugin.
    public func grant(for plugin: CmuxLoadedPlugin) -> CmuxPluginGrant {
        loadIfNeeded()
        return loadedGrant(for: plugin)
    }

    /// Returns a diagnostic when an existing grant file could not be loaded.
    public func storageLoadFailure() -> CmuxPluginPermissionStoreLoadFailure? {
        loadIfNeeded()
        return loadFailure
    }

    private func loadedGrant(for plugin: CmuxLoadedPlugin) -> CmuxPluginGrant {
        guard let grant = grants[plugin.manifest.id],
              grant.pluginID == plugin.manifest.id,
              grant.manifestFingerprint == plugin.manifestFingerprint else {
            return CmuxPluginGrant(
                pluginID: plugin.manifest.id,
                manifestFingerprint: plugin.manifestFingerprint
            )
        }
        return grant
    }

    /// Returns the fail-closed effective permissions for `plugin`.
    public func permissions(for plugin: CmuxLoadedPlugin) -> CmuxPluginPermissions {
        grant(for: plugin).effectivePermissions(for: plugin)
    }

    /// Approves every capability currently declared by `plugin` and enables it.
    /// Hosts should call this only from an explicit user action.
    public func approveAll(for plugin: CmuxLoadedPlugin) throws {
        try prepareForMutation()
        let manifest = plugin.manifest
        let grant = CmuxPluginGrant(
            pluginID: manifest.id,
            manifestFingerprint: plugin.manifestFingerprint,
            enabled: true,
            approved: true,
            readScopes: Set(manifest.readScopes),
            actionScopes: Set(manifest.actionScopes),
            pluginScopes: manifest.requestedPluginScopes,
            events: Set(manifest.eventSubscriptions),
            actions: Set(manifest.actions.map(\.id))
        )
        try saveLoaded(grant)
    }

    /// Enables or disables a plugin without changing its approved scopes.
    public func setEnabled(_ enabled: Bool, for plugin: CmuxLoadedPlugin) throws {
        try prepareForMutation()
        var grant = loadedGrant(for: plugin)
        if enabled && !grant.approved {
            throw CmuxPluginAuthorizationError.notApproved
        }
        grant.enabled = enabled
        try saveLoaded(grant)
    }

    /// Replaces a grant after a Settings permission review.
    public func setGrant(_ grant: CmuxPluginGrant) throws {
        try prepareForMutation()
        try saveLoaded(grant)
    }

    /// Removes a plugin's persisted approval.
    public func revoke(pluginID: String) throws {
        try prepareForMutation()
        var next = grants
        next.removeValue(forKey: pluginID)
        try persist(next)
        grants = next
    }

    private func saveLoaded(_ grant: CmuxPluginGrant) throws {
        var next = grants
        next[grant.pluginID] = grant
        try persist(next)
        grants = next
    }

    private func persist(_ grants: [String: CmuxPluginGrant]) throws {
        guard let storageURL else { return }
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = FileEnvelope(schemaVersion: Self.schemaVersion, grants: grants)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: storageURL, options: [.atomic])
    }

    private func prepareForMutation() throws {
        loadIfNeeded()
        if let loadFailure {
            throw loadFailure
        }
    }

    private func loadIfNeeded() {
        let signature = currentFileSignature()
        guard !hasLoaded || signature != loadedFileSignature else { return }
        hasLoaded = true
        loadedFileSignature = signature
        grants.removeAll()
        loadFailure = nil
        guard let storageURL,
              fileManager.fileExists(atPath: storageURL.path) else {
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: storageURL)
        } catch {
            loadFailure = .unreadableFile
            return
        }

        let envelope: FileEnvelope
        do {
            envelope = try JSONDecoder().decode(FileEnvelope.self, from: data)
        } catch {
            loadFailure = .malformedFile
            return
        }
        guard envelope.schemaVersion == Self.schemaVersion else {
            loadFailure = .unsupportedSchemaVersion(envelope.schemaVersion)
            return
        }
        grants = envelope.grants
    }

    /// Reads only filesystem metadata to detect an external grant-file edit.
    /// The actual JSON read remains inside this actor's executor and is only
    /// performed when the signature changes.
    private func currentFileSignature() -> FileSignature {
        guard let storageURL else { return .missing }
        guard let attributes = try? fileManager.attributesOfItem(atPath: storageURL.path) else {
            return .missing
        }
        return FileSignature(
            exists: true,
            byteCount: attributes[.size] as? Int,
            modificationDate: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}
