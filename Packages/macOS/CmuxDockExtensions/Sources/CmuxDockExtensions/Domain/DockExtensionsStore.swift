import Foundation
import Observation

/// The Dock-extensions domain model: the installed set projected from the
/// lockfile, plus every mutation — preview, install, update, uninstall,
/// link/unlink, enable/disable, and pane launch.
///
/// Every entrypoint (Settings, command palette, Dock empty view, and later the
/// CLI/socket verbs and `cmux://` deep links) funnels through this one store,
/// per the shared-behavior policy: the consent flow is `preview → user
/// confirmation → install(preview)`, and nothing runs before `install`.
///
/// `@MainActor @Observable`; file/git/build work happens on the injected
/// service actors (or detached projection tasks), never on the main actor.
@MainActor
@Observable
public final class DockExtensionsStore {
    /// The installed/linked extensions, projected against what is on disk.
    public private(set) var installed: [InstalledDockExtension] = []

    /// Whether a reload is in flight.
    public private(set) var isLoading = false

    /// Extension ids with an install/update/uninstall currently running.
    public private(set) var busyExtensionIds: Set<String> = []

    /// Human-readable lockfile load failure, when the last reload failed.
    public private(set) var loadError: String?

    private let directories: DockExtensionDirectories
    private let repository: InstalledDockExtensionsRepository
    private let gitService: DockExtensionGitService
    private let buildRunner: DockExtensionBuildRunner
    private let manifestLoader: DockExtensionManifestLoader
    private weak var host: (any DockExtensionsHost)?
    /// Staging directories belonging to previews awaiting consent; excluded
    /// from stale-staging cleanup.
    private var activeStagingPaths: Set<String> = []
    /// Monotonic reload ticket: `reload()` is reentrant across its awaits, so
    /// only the newest reload may publish its projection — an older reload
    /// finishing late must never overwrite fresher installed state.
    private var reloadGeneration = 0

    /// Creates the store. Constructed once at the app's composition root.
    public init(
        directories: DockExtensionDirectories,
        repository: InstalledDockExtensionsRepository,
        gitService: DockExtensionGitService = DockExtensionGitService(),
        buildRunner: DockExtensionBuildRunner = DockExtensionBuildRunner(),
        manifestLoader: DockExtensionManifestLoader = DockExtensionManifestLoader()
    ) {
        self.directories = directories
        self.repository = repository
        self.gitService = gitService
        self.buildRunner = buildRunner
        self.manifestLoader = manifestLoader
    }

    /// Attaches the app-side host bridge (Dock pane opening, beta-flag
    /// activation). Set once at the composition root, after both sides exist.
    public func attachHost(_ host: any DockExtensionsHost) {
        self.host = host
    }

    /// The installed extension with `id`, if any.
    public func installedExtension(id: String) -> InstalledDockExtension? {
        installed.first { $0.id == id }
    }

    // MARK: - Loading

    /// Re-reads the lockfile and re-projects every record against disk.
    public func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        defer { if generation == reloadGeneration { isLoading = false } }
        let lockFile: DockExtensionsLockFile
        do {
            lockFile = try await repository.load()
        } catch {
            guard generation == reloadGeneration else { return }
            loadError = error.localizedDescription
            installed = []
            return
        }
        let records = lockFile.extensions
        let directories = self.directories
        let loader = self.manifestLoader
        let projected = await Task.detached(priority: .userInitiated) {
            Self.project(records: records, directories: directories, loader: loader)
        }.value
        // A newer reload started while this one was suspended: its snapshot is
        // fresher (it observed later lockfile state), so drop this one.
        guard generation == reloadGeneration else { return }
        loadError = nil
        installed = projected
        cleanUpStaleStaging()
    }

    // MARK: - Preview (consent input)

    /// Resolves and stages a GitHub install without running anything: pins
    /// the ref to a commit SHA, materializes a staged checkout, and parses the
    /// manifest. The result is what the consent UI shows; nothing from the
    /// extension executes until ``install(_:)``.
    public func previewInstall(input: String, ref: String? = nil) async throws -> DockExtensionInstallPreview {
        guard let source = DockExtensionSource.parseGitHub(input) else {
            throw DockExtensionError.invalidSource(input)
        }
        guard let cloneURL = source.cloneURLString else {
            throw DockExtensionError.invalidSource(input)
        }
        let sha = try await gitService.resolveRemoteRevision(cloneURL: cloneURL, ref: ref)
        let staging = directories.makeStagingDirectory()
        activeStagingPaths.insert(staging.path)
        do {
            try await gitService.materializeCheckout(cloneURL: cloneURL, sha: sha, into: staging)
            let manifestDirectory = Self.applySubdirectory(source.subdirectory, to: staging)
            let loader = manifestLoader
            let manifest = try await Task.detached {
                try loader.load(fromDirectory: manifestDirectory)
            }.value
            try validateForInstall(manifest)
            let kind = try previewKind(for: manifest.id, source: source)
            return DockExtensionInstallPreview(
                source: source,
                resolvedSha: sha,
                ref: ref,
                manifest: manifest,
                stagingDirectory: staging,
                warnings: Self.warnings(for: manifest),
                kind: kind
            )
        } catch {
            discardStaging(staging)
            throw error
        }
    }

    /// Stages an update of an installed GitHub extension: re-resolves its ref
    /// (or the default branch) and returns a consent preview against the new
    /// commit. Linked extensions have nothing to update.
    public func previewUpdate(id: String) async throws -> DockExtensionInstallPreview {
        guard let existing = installedExtension(id: id) else {
            throw DockExtensionError.notInstalled(id: id)
        }
        guard case .github = existing.record.source else {
            throw DockExtensionError.invalidSource(existing.record.source.description)
        }
        let preview = try await previewInstall(
            input: existing.record.source.description,
            ref: existing.record.ref
        )
        // An update must stay an update: if the repo's manifest changed its id,
        // confirming would install a SECOND extension and leave the old record
        // behind. Refuse instead of silently forking.
        guard preview.manifest.id == id else {
            discard(preview)
            throw DockExtensionError.manifestInvalid([
                "the repository's manifest id changed from \"\(id)\" to \"\(preview.manifest.id)\"; uninstall \"\(id)\" and install the new id instead",
            ])
        }
        return preview
    }

    /// Deletes a preview's staged checkout after the user cancels consent.
    public func discard(_ preview: DockExtensionInstallPreview) {
        guard let staging = preview.stagingDirectory else { return }
        discardStaging(staging)
    }

    // MARK: - Install / uninstall

    /// Executes a consented preview: runs build steps in the staged checkout,
    /// moves it into the managed checkouts directory, records the pin +
    /// consent fingerprint, and activates the Dock beta feature.
    public func install(_ preview: DockExtensionInstallPreview) async throws {
        let id = preview.manifest.id
        guard let staging = preview.stagingDirectory else {
            throw DockExtensionError.stagingFailed(detail: "preview has no staged checkout")
        }
        guard busyExtensionIds.insert(id).inserted else {
            // Callers (socket install, GUI coordinator) must see the truth: a
            // silent return here reported skipped installs as successes.
            throw DockExtensionError.operationInProgress(id: id)
        }
        defer { busyExtensionIds.remove(id) }

        let previousRecord = installedExtension(id: id)?.record
        let destination = directories.checkoutDirectory(id: id)
        do {
            let buildRoot = Self.applySubdirectory(preview.source.subdirectory, to: staging)
            try await buildRunner.runBuildSteps(
                preview.manifest.buildStepsForCurrentPlatform,
                in: buildRoot,
                logsDirectory: directories.logsDirectory(id: id)
            )
            try await Task.detached {
                try Self.moveIntoPlace(staging: staging, destination: destination)
            }.value
            activeStagingPaths.remove(staging.path)
        } catch {
            discardStaging(staging)
            throw error
        }

        let record = DockExtensionInstallRecord(
            id: id,
            source: preview.source,
            pinnedSha: preview.resolvedSha,
            ref: preview.ref,
            installedAt: Date(),
            // An update must not silently re-enable an extension the user
            // disabled in Settings; re-consent covers the code, not the toggle.
            enabled: previousRecord?.enabled ?? true,
            consentFingerprint: preview.consentFingerprint
        )
        do {
            try await repository.upsert(record)
        } catch {
            // A fresh install that failed to record must not leave an
            // untracked checkout behind. On an update the previous record
            // still points at this directory, so keep the files (the
            // projection reports needsReconsent until a retry succeeds).
            if previousRecord == nil {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
        await reload()
        host?.activateDockForExtensions()
    }

    /// Removes an extension's record and its managed checkout. The user's
    /// per-extension config and state directories are preserved.
    public func uninstall(id: String) async throws {
        guard let existing = installedExtension(id: id) else {
            throw DockExtensionError.notInstalled(id: id)
        }
        guard busyExtensionIds.insert(id).inserted else {
            throw DockExtensionError.operationInProgress(id: id)
        }
        defer { busyExtensionIds.remove(id) }
        try await repository.remove(id: id)
        if !existing.isLinked {
            // Containment check: the id comes from the decoded lockfile, which
            // other tooling can write. A malformed id (e.g. "../x") must never
            // turn this delete into a traversal outside the managed checkouts
            // directory — refuse the file deletion, keep the record removal.
            let checkoutsRoot = directories.checkoutDirectory(id: "x")
                .deletingLastPathComponent().standardizedFileURL
            let checkout = directories.checkoutDirectory(id: id).standardizedFileURL
            if DockExtensionManifest.isValidExtensionId(id),
               checkout.path.hasPrefix(checkoutsRoot.path + "/") {
                try? FileManager.default.removeItem(at: checkout)
            }
        }
        await reload()
    }

    /// Enables or disables an installed extension's panes.
    public func setEnabled(id: String, enabled: Bool) async throws {
        try await repository.updateRecord(id: id) { $0.enabled = enabled }
        await reload()
    }

    // MARK: - Link / unlink (development)

    /// Registers a local directory as a development extension (herdr's
    /// `plugin link`): the manifest is validated but build steps never run and
    /// nothing is copied — panes launch straight from the directory.
    public func link(directoryPath: String) async throws {
        let expanded = (directoryPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DockExtensionError.linkedDirectoryMissing(path: url.path)
        }
        let loader = manifestLoader
        let manifest = try await Task.detached {
            try loader.load(fromDirectory: url)
        }.value
        try validateForInstall(manifest)
        // Exact-id re-link of a linked extension refreshes it; anything else
        // sharing the id (including a case-only difference — ids name on-disk
        // directories on case-insensitive APFS) is a collision.
        if let existing = installed.first(where: {
            $0.id.caseInsensitiveCompare(manifest.id) == .orderedSame
        }), existing.id != manifest.id || !existing.isLinked {
            throw DockExtensionError.duplicateId(existing.id)
        }
        let record = DockExtensionInstallRecord(
            id: manifest.id,
            source: .local(path: url.path),
            pinnedSha: nil,
            installedAt: Date(),
            enabled: true,
            consentFingerprint: manifest.consentFingerprint(pinnedSha: nil)
        )
        try await repository.upsert(record)
        await reload()
        host?.activateDockForExtensions()
    }

    /// Removes an extension's record without touching any files (herdr's
    /// `plugin unlink`).
    public func unlink(id: String) async throws {
        guard installedExtension(id: id) != nil else {
            throw DockExtensionError.notInstalled(id: id)
        }
        try await repository.remove(id: id)
        await reload()
    }

    // MARK: - Pane launch

    /// Opens one extension pane in the active window's Dock.
    public func openPane(extensionId: String, paneId: String) throws {
        let qualifiedId = DockExtensionPane.qualifiedId(extensionId: extensionId, paneId: paneId)
        guard let installedExt = installedExtension(id: extensionId) else {
            throw DockExtensionError.notInstalled(id: extensionId)
        }
        guard installedExt.record.enabled else {
            throw DockExtensionError.extensionDisabled(id: extensionId)
        }
        if installedExt.status == .needsReconsent {
            throw DockExtensionError.needsReconsent(id: extensionId)
        }
        guard let manifest = installedExt.manifest else {
            throw DockExtensionError.manifestNotFound(path: installedExt.rootDirectory.path)
        }
        guard let pane = manifest.pane(withId: paneId),
              DockExtensionManifest.appliesToCurrentPlatform(pane.platforms) else {
            throw DockExtensionError.paneNotFound(qualifiedId: qualifiedId)
        }
        guard let host else {
            throw DockExtensionError.hostUnavailable
        }

        let configDirectory = directories.configDirectory(id: extensionId)
        let stateDirectory = directories.stateDirectory(id: extensionId)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

        let root = installedExt.rootDirectory
        var workingDirectory = root
        if let cwd = pane.cwd {
            workingDirectory = root.appendingPathComponent(cwd, isDirectory: true)
        }

        var environment = pane.env
        environment["CMUX_EXTENSION_ID"] = extensionId
        environment["CMUX_EXTENSION_PANE_ID"] = pane.id
        environment["CMUX_EXTENSION_ROOT"] = root.path
        environment["CMUX_EXTENSION_CONFIG_DIR"] = configDirectory.path
        environment["CMUX_EXTENSION_STATE_DIR"] = stateDirectory.path
        environment["CMUX_EXTENSION_ENV"] = "1"

        let title = manifest.panes.count == 1
            ? manifest.name
            : "\(manifest.name): \(pane.title)"
        let request = DockExtensionPaneOpenRequest(
            controlId: qualifiedId,
            title: title,
            iconSystemName: manifest.iconSystemName,
            shellCommand: pane.shellCommand,
            workingDirectory: workingDirectory.path,
            environment: environment
        )
        guard host.openExtensionPane(request) else {
            throw DockExtensionError.hostUnavailable
        }
    }

    /// Opens a pane by its qualified `<extensionId>.<paneId>` id.
    public func openPane(qualifiedId: String) throws {
        guard let (extensionId, paneId) = DockExtensionPane.splitQualifiedId(qualifiedId) else {
            throw DockExtensionError.paneNotFound(qualifiedId: qualifiedId)
        }
        try openPane(extensionId: extensionId, paneId: paneId)
    }

    // MARK: - Validation helpers

    private func validateForInstall(_ manifest: DockExtensionManifest) throws {
        guard manifest.appliesToCurrentPlatform else {
            throw DockExtensionError.platformNotSupported(id: manifest.id)
        }
        if let minimum = manifest.minCmuxVersion, let host,
           let current = DockExtensionVersion(host.currentAppVersion),
           current < minimum {
            throw DockExtensionError.minCmuxVersionNotSatisfied(
                required: minimum.rawValue,
                current: current.rawValue
            )
        }
    }

    private func previewKind(
        for id: String,
        source: DockExtensionSource
    ) throws -> DockExtensionInstallPreview.Kind {
        // Ids name on-disk directories and APFS is case-insensitive by
        // default, so "MyExt" and "myext" would share one checkout and
        // overwrite each other. Refuse case-colliding ids outright.
        if let collision = installed.first(where: {
            $0.id != id && $0.id.caseInsensitiveCompare(id) == .orderedSame
        }) {
            throw DockExtensionError.duplicateId(collision.id)
        }
        guard let existing = installedExtension(id: id) else { return .install }
        guard existing.record.source == source else {
            throw DockExtensionError.duplicateId(id)
        }
        return .update(previousSha: existing.record.pinnedSha)
    }

    private static func warnings(for manifest: DockExtensionManifest) -> [String] {
        var warnings: [String] = []
        if !manifest.unknownTopLevelKeys.isEmpty {
            warnings.append(
                String(
                    localized: "dockExtensions.warning.unknownSections",
                    defaultValue: "This manifest declares sections this cmux version ignores: \(manifest.unknownTopLevelKeys.joined(separator: ", "))"
                )
            )
        }
        for pane in manifest.panes {
            if let placement = pane.placement, placement != "dock" {
                warnings.append(
                    String(
                        localized: "dockExtensions.warning.placement",
                        defaultValue: "Pane \"\(pane.id)\" requests placement \"\(placement)\"; it will open in the Dock."
                    )
                )
            }
        }
        if manifest.panesForCurrentPlatform.isEmpty {
            warnings.append(
                String(
                    localized: "dockExtensions.warning.noMacPanes",
                    defaultValue: "This extension declares no panes for macOS."
                )
            )
        }
        return warnings
    }

    // MARK: - Staging + projection

    private func discardStaging(_ staging: URL) {
        activeStagingPaths.remove(staging.path)
        try? FileManager.default.removeItem(at: staging)
    }

    /// Deletes leftover staged checkouts (crashed/cancelled previews from
    /// earlier runs), sparing directories that back a preview currently
    /// awaiting consent.
    private func cleanUpStaleStaging() {
        guard busyExtensionIds.isEmpty else { return }
        let stagingRoot = directories.stagingRoot
        Task.detached(priority: .background) { [weak self] in
            let fileManager = FileManager.default
            guard let children = try? fileManager.contentsOfDirectory(
                at: stagingRoot,
                includingPropertiesForKeys: nil
            ) else { return }
            // Snapshot the active set AFTER listing: previews register their
            // staging path before creating the directory, so every live
            // staged checkout that made it into `children` is already in this
            // snapshot — a preview started mid-cleanup can never be deleted.
            guard let active = await self?.stagingPathsActiveNow() else { return }
            for child in children where !active.contains(child.path) {
                try? fileManager.removeItem(at: child)
            }
        }
    }

    /// The staging paths belonging to previews/installs alive right now
    /// (main-actor read for the cleanup task's post-listing snapshot).
    private func stagingPathsActiveNow() -> Set<String> {
        activeStagingPaths
    }
}
