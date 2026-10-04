public import Foundation
public import Observation

/// One app the registry knows, with its install and grant state.
public nonisolated struct InstalledApp: Sendable, Hashable, Identifiable {
    public var bundle: AppBundle
    public var isInstalled: Bool
    public var isEnabled: Bool
    /// Installed but hidden from the sidebar, palette and menus.
    public var isHidden: Bool
    public var tier: AppStoreTier
    public var revokedScopes: Set<String>
    public var grantedOptionalScopes: Set<String>
    /// The user's sandbox switch, else the tier default (unverified: on).
    public var isSandboxed: Bool
    public var id: String { bundle.id }
    public var manifest: AppManifest { bundle.manifest }
    /// Installed and enabled: it runs and answers granted calls.
    public var isActive: Bool { isInstalled && isEnabled }
    /// Active and not hidden: its sidebar, palette and menu contributions show.
    public var isVisible: Bool { isActive && !isHidden }

    init(bundle: AppBundle, entry: AppRegistryFile.Entry) {
        self.bundle = bundle
        isInstalled = entry.installed
        isEnabled = entry.enabled
        isHidden = entry.hidden
        tier = AppStoreTier.local(bundle.manifest)
        revokedScopes = Set(entry.revokedScopes)
        grantedOptionalScopes = Set(entry.grantedOptionalScopes)
        isSandboxed = entry.sandboxed ?? (tier == .unverified)
    }

    /// Whether a requested or optional scope is granted now. Unverified
    /// apps get read scopes by default; a write scope needs the user to
    /// turn it on (it then counts as granted).
    public func isGranted(_ scope: String) -> Bool {
        if manifest.optionalScopes.contains(where: { $0.scope == scope }) { return grantedOptionalScopes.contains(scope) }
        guard manifest.scopes.contains(where: { $0.scope == scope }), !revokedScopes.contains(scope) else { return false }
        return tier != .unverified || Self.isRead(scope) || grantedOptionalScopes.contains(scope)
    }

    /// What the engine enforces (`AppGrants`); nothing while not active.
    public var grants: AppGrants.Snapshot {
        guard isActive else { return AppGrants.Snapshot(scopes: [], sandboxed: true) }
        let declared = (manifest.scopes + manifest.optionalScopes).map(\.scope)
        return AppGrants.Snapshot(scopes: Set(declared.filter(isGranted)), sandboxed: isSandboxed)
    }

    static func isRead(_ scope: String) -> Bool { scope.hasSuffix(":read") }
}

/// PROTOTYPE app registry (app-platform.md step 5): the apps this machine
/// can run (bundled first-party samples, then `local/` development apps)
/// and their install/enable state from `registry.json`. A temporary
/// stand-in for UserDO installs; when the store backend lands, installs
/// come from the cloud install record and this becomes its mirror. Only
/// user-initiated App Store buttons change installs (no CLI or MCP path;
/// Lawrence 2026-10-02: agents cannot install apps until the actor stamp
/// lands).
@MainActor
@Observable
public final class AppRegistry {
    public private(set) var apps: [InstalledApp] = []
    public private(set) var problems: [AppBundleScanner.Problem] = []
    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let bundledRoot: URL
    @ObservationIgnored private let firstPartyRoot: URL
    /// Set once the first scan finished (the store waits on it instead of scanning itself).
    public private(set) var isLoaded = false
    @ObservationIgnored private var file = AppRegistryFile()
    /// Called after an app's state changed (the host refreshes its grants).
    @ObservationIgnored public var onChange: ((InstalledApp) -> Void)?

    /// - Parameters:
    ///   - directory: the tag's apps directory (`AppRegistryFile.appsDirectory(tag:)`).
    ///   - bundledRoot: where the first-party samples live (the module's resources).
    public init(directory: URL, bundledRoot: URL = AppPlatformResources.samples, firstPartyRoot: URL = AppPlatformResources.firstParty) {
        self.firstPartyRoot = firstPartyRoot
        self.directory = directory
        self.bundledRoot = bundledRoot
    }

    var fileURL: URL { directory.appending(path: "registry.json") }
    /// `local/` development apps: one directory each.
    public var localRoot: URL { directory.appending(path: "local", directoryHint: .isDirectory) }

    /// Scans bundles and reads the record off the main actor.
    public func load() async {
        let (bundledRoot, firstPartyRoot, localRoot, fileURL) = (self.bundledRoot, self.firstPartyRoot, self.localRoot, self.fileURL)
        let (bundles, problems, file) = await Task.detached(priority: .utility) {
            let firstParty = AppBundleScanner.scan(firstPartyRoot, source: .firstParty)
            let samples = AppBundleScanner.scan(bundledRoot, source: .bundled)
            let bundled = (bundles: firstParty.bundles + samples.bundles, problems: firstParty.problems + samples.problems)
            let local = AppBundleScanner.scan(localRoot, source: .local)
            return (bundled.bundles + local.bundles, bundled.problems + local.problems, AppRegistryFile.load(from: fileURL))
        }.value
        self.file = file
        self.problems = problems
        var seen = Set<String>()
        apps = bundles.filter { seen.insert($0.id).inserted }.map { InstalledApp(bundle: $0, entry: Self.entry(for: $0, in: file)) }
        isLoaded = true
    }

    public func app(_ id: String) -> InstalledApp? { apps.first { $0.id == id } }
    public var active: [InstalledApp] { apps.filter(\.isActive) }

    public func install(_ id: String) async throws { try await update(id) { $0.installed = true; $0.enabled = true } }
    /// First-party apps can only be hidden, never removed (Lawrence,
    /// FIRST-PARTY-APPS); `remove` refuses them.
    public func remove(_ id: String) async throws {
        if app(id)?.bundle.source == .firstParty { throw AppRegistryError.firstPartyHideOnly(id) }
        try await update(id) { $0.installed = false }
    }
    public func setEnabled(_ id: String, _ enabled: Bool) async throws { try await update(id) { $0.enabled = enabled } }
    public func setHidden(_ id: String, _ hidden: Bool) async throws { try await update(id) { $0.hidden = hidden } }

    /// Development apps are installed as soon as they are in the local directory; bundled samples are opt-in.
    nonisolated static func installedByDefault(_ bundle: AppBundle) -> Bool { bundle.source == .local || bundle.source == .firstParty }

    /// The record of `bundle`, with the shipped defaults when none exists. A
    /// first-party app is always installed: a record that removed one (the
    /// earlier removable behavior) reads as hidden instead.
    nonisolated static func entry(for bundle: AppBundle, in file: AppRegistryFile) -> AppRegistryFile.Entry {
        var entry = file.entry(bundle.id, installedByDefault: installedByDefault(bundle))
        guard bundle.source == .firstParty else { return entry }
        // Shipped hidden (manifest presentation.hiddenByDefault, the field the
        // supervisor reads too): installed, reachable from the palette and
        // the App Store, not in the sidebar until shown.
        if file.apps[bundle.id] == nil, bundle.manifest.presentation?.hiddenByDefault == true { entry.hidden = true }
        if !entry.installed {
            entry.installed = true
            entry.hidden = true
        }
        return entry
    }

    /// Grants or revokes one scope (takes effect on the app's next call).
    public func setGranted(_ id: String, scope: String, _ granted: Bool) async throws {
        guard let app = app(id) else { return }
        let optional = app.manifest.optionalScopes.contains { $0.scope == scope }
        let unverifiedWrite = app.tier == .unverified && !InstalledApp.isRead(scope)
        try await update(id) { entry in
            if optional || unverifiedWrite {
                entry.grantedOptionalScopes.removeAll { $0 == scope }
                if granted { entry.grantedOptionalScopes.append(scope) }
            }
            if !optional {
                entry.revokedScopes.removeAll { $0 == scope }
                if !granted { entry.revokedScopes.append(scope) }
            }
        }
    }

    /// The "Run sandboxed" switch.
    public func setSandboxed(_ id: String, _ sandboxed: Bool) async throws { try await update(id) { $0.sandboxed = sandboxed } }

    private func update(_ id: String, _ change: (inout AppRegistryFile.Entry) -> Void) async throws {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        var entry = Self.entry(for: apps[index].bundle, in: file)
        change(&entry)
        entry.changedAt = Date()
        var next = file
        next.apps[id] = entry
        let url = fileURL
        let snapshot = next
        try await Task.detached(priority: .utility) { try snapshot.save(to: url) }.value
        file = next
        apps[index] = InstalledApp(bundle: apps[index].bundle, entry: entry)
        onChange?(apps[index])
    }
}
