/// Where an app came from (`apps-list` `source`).
public nonisolated enum AppSource: String, Sendable, Hashable, CaseIterable {
    /// A first-party app on the deployment's default list: installed for
    /// everyone, its required scopes granted without a consent sheet.
    case `default`
    /// Installed by the user from the App Store.
    case user
    /// Shipped inside cmux, opt-in.
    case bundled
    /// A `local/` development app.
    case local
}

/// Which automation paths still reach a hidden app (V9; default all true).
public nonisolated struct AppHiddenAccess: Sendable, Hashable {
    public var cli: Bool
    public var mcp: Bool
    public var automations: Bool

    public init(cli: Bool = true, mcp: Bool = true, automations: Bool = true) {
        self.cli = cli
        self.mcp = mcp
        self.automations = automations
    }
}

/// One app in the supervisor's install mirror (one `apps-list` entry, and
/// the reply of `apps-set`). The daemon owns every field; the client only
/// renders it.
public nonisolated struct AppRecord: Sendable, Hashable, Identifiable {
    public var id: String
    public var version: String
    public var tier: AppStoreTier
    public var installed: Bool
    public var enabled: Bool
    public var hidden: Bool
    public var hiddenAccess: AppHiddenAccess
    public var source: AppSource
    /// Granted scopes.
    public var grants: Set<String>
    public var sandboxed: Bool
    public var manifest: AppManifest

    public init(manifest: AppManifest, tier: AppStoreTier, installed: Bool, enabled: Bool = true, hidden: Bool = false,
                hiddenAccess: AppHiddenAccess = AppHiddenAccess(), source: AppSource, grants: Set<String> = [], sandboxed: Bool = false) {
        id = manifest.id
        version = manifest.version
        self.tier = tier
        self.installed = installed
        self.enabled = enabled
        self.hidden = hidden
        self.hiddenAccess = hiddenAccess
        self.source = source
        self.grants = grants
        self.sandboxed = sandboxed
        self.manifest = manifest
    }

    /// Installed and enabled: it runs and answers granted calls.
    public var isActive: Bool { installed && enabled }
    /// Active and not hidden: its sidebar, palette and menu presence shows.
    public var isVisible: Bool { isActive && !hidden }
    /// Installed for everyone by the deployment (no consent, no remove).
    public var isDefault: Bool { source == .default }
    public func isGranted(_ scope: String) -> Bool { grants.contains(scope) }

    /// Decodes one wire record; nil when a required field is missing.
    public init?(json: AppJSON) {
        guard let manifest = json["manifest"].flatMap(AppManifest.init(json:)), let id = json["id"]?.stringValue,
              id == manifest.id else { return nil }
        self.id = id
        self.manifest = manifest
        version = json["version"]?.stringValue ?? manifest.version
        tier = json["tier"]?.stringValue.flatMap(AppStoreTier.init(rawValue:)) ?? AppStoreTier.local(manifest)
        installed = json["installed"]?.boolValue ?? false
        enabled = json["enabled"]?.boolValue ?? true
        hidden = json["hidden"]?.boolValue ?? false
        let access = json["hidden_access"]
        hiddenAccess = AppHiddenAccess(cli: access?["cli"]?.boolValue ?? true, mcp: access?["mcp"]?.boolValue ?? true,
                                       automations: access?["automations"]?.boolValue ?? true)
        source = json["source"]?.stringValue.flatMap(AppSource.init(rawValue:)) ?? .user
        grants = Set(json["grants"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        sandboxed = json["sandboxed"]?.boolValue ?? false
    }

    /// The wire shape (the fake transport answers with it).
    public var json: AppJSON {
        [
            "id": .string(id), "version": .string(version), "tier": .string(tier.rawValue), "installed": .bool(installed),
            "enabled": .bool(enabled), "hidden": .bool(hidden), "source": .string(source.rawValue), "sandboxed": .bool(sandboxed),
            "hidden_access": ["cli": .bool(hiddenAccess.cli), "mcp": .bool(hiddenAccess.mcp), "automations": .bool(hiddenAccess.automations)],
            "grants": .array(grants.sorted().map(AppJSON.string)), "manifest": manifest.raw,
        ]
    }
}
