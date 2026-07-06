import AppKit
import CmuxDockExtensions
import CmuxSettingsUI
import Foundation
import Observation

/// App-target composition root for Dock TUI extensions: builds the domain
/// store over the standard on-disk layout, bridges it to the Dock and
/// Settings, and owns the consent flow. Composed as a singleton like the app
/// target's window controllers.
@MainActor
final class DockExtensionsRuntime {
    static let shared = DockExtensionsRuntime()

    /// The community marketplace. Interim destination: the GitHub topic page
    /// (the same source the gallery indexes), guaranteed live today. Flip to
    /// `https://ncmux.com/extensions` once the gallery PR (#7416) deploys to
    /// production — the site's canonical domain is ncmux.com (web/i18n/seo.ts).
    static let marketplaceURL = URL(string: "https://github.com/topics/cmux-extension")!

    /// The extensions domain model every entrypoint funnels through.
    let store: DockExtensionsStore

    /// The consent flow (preview → confirm → install) shared by Settings,
    /// the command palette, and later the CLI/deep-link entrypoints.
    let installCoordinator: ExtensionInstallCoordinator

    private let host: DockExtensionsAppHost
    private let directories: DockExtensionDirectories
    private var settingsState: ExtensionsSettingsState?
    /// Consent previews minted for socket/CLI flows, keyed by token; the CLI
    /// renders the preview, asks the user, then confirms or discards by token.
    private var socketPreviewGrants: [String: SocketPreviewGrant] = [:]

    private struct SocketPreviewGrant {
        let preview: DockExtensionInstallPreview
        let createdAt: Date
    }

    /// How long an unconfirmed socket preview (and its staged checkout) lives.
    static let socketPreviewLifetime: TimeInterval = 15 * 60

    private init() {
        let directories = DockExtensionDirectories(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        self.directories = directories
        let store = DockExtensionsStore(
            directories: directories,
            repository: InstalledDockExtensionsRepository(fileURL: directories.lockFileURL)
        )
        self.store = store
        self.host = DockExtensionsAppHost()
        self.installCoordinator = ExtensionInstallCoordinator(store: store)
        store.attachHost(host)
        Task { await store.reload() }
    }

    /// Opens a pane by qualified id, beeping on failure (launcher surfaces
    /// that have no better error affordance).
    func openPaneOrBeep(qualifiedId: String) {
        do {
            try store.openPane(qualifiedId: qualifiedId)
        } catch {
            NSSound.beep()
            settingsState?.lastErrorMessage = error.localizedDescription
        }
    }

    /// The single Settings-section state instance, created on first request
    /// and mirrored from the store for the app's lifetime.
    func dockExtensionsSettingsState() -> ExtensionsSettingsState {
        if let settingsState { return settingsState }
        let state = ExtensionsSettingsState()
        state.actions = ExtensionsSettingsState.Actions(
            refresh: { [weak self] in
                guard let self else { return }
                Task { await self.store.reload() }
            },
            installFromInput: { [weak self] input in
                self?.installCoordinator.beginInstall(input: input)
            },
            openPane: { [weak self] qualifiedId in
                self?.openPaneOrBeep(qualifiedId: qualifiedId)
            },
            setEnabled: { [weak self] id, enabled in
                self?.performReportingErrors { try await $0.setEnabled(id: id, enabled: enabled) }
            },
            update: { [weak self] id in
                self?.installCoordinator.beginUpdate(id: id)
            },
            uninstall: { [weak self] id in
                self?.performReportingErrors { try await $0.uninstall(id: id) }
            },
            browseMarketplace: {
                NSWorkspace.shared.open(Self.marketplaceURL)
            }
        )
        settingsState = state
        mirrorStore(into: state)
        return state
    }

    /// Launchable panes across every installed extension, for the palette and
    /// the Dock empty-pane launcher: `(qualifiedId, title, icon)`.
    var launchablePaneItems: [(qualifiedId: String, title: String, iconSystemName: String)] {
        store.installed.flatMap { installed in
            installed.launchablePanes.map { pane in
                let title = installed.launchablePanes.count == 1
                    ? installed.displayName
                    : "\(installed.displayName): \(pane.title)"
                return (
                    qualifiedId: DockExtensionPane.qualifiedId(extensionId: installed.id, paneId: pane.id),
                    title: title,
                    iconSystemName: installed.iconSystemName
                )
            }
        }
    }

    // MARK: - Socket/CLI consent flow

    /// Stages a preview for `cmux extension install/update` and returns a
    /// one-shot token the CLI confirms or discards after showing the preview.
    func socketPreview(
        sourceInput: String?,
        updateId: String?,
        ref: String?
    ) async throws -> (token: String, preview: DockExtensionInstallPreview) {
        expireStaleSocketPreviews()
        let preview: DockExtensionInstallPreview
        if let updateId, !updateId.isEmpty {
            preview = try await store.previewUpdate(id: updateId)
        } else if let sourceInput, !sourceInput.isEmpty {
            preview = try await store.previewInstall(input: sourceInput, ref: ref)
        } else {
            throw DockExtensionError.invalidSource("")
        }
        let token = UUID().uuidString.lowercased()
        socketPreviewGrants[token] = SocketPreviewGrant(preview: preview, createdAt: Date())
        return (token, preview)
    }

    /// Executes a previously granted preview. Returns `nil` for an unknown or
    /// expired token.
    func socketInstall(token: String) async throws -> DockExtensionInstallPreview? {
        guard let grant = socketPreviewGrants.removeValue(forKey: token) else { return nil }
        try await store.install(grant.preview)
        return grant.preview
    }

    /// Discards a granted preview's staged checkout (the CLI's "n" answer).
    /// Returns `false` for an unknown or expired token.
    func socketDiscard(token: String) -> Bool {
        guard let grant = socketPreviewGrants.removeValue(forKey: token) else { return false }
        store.discard(grant.preview)
        return true
    }

    /// The on-disk locations for an installed extension (for
    /// `cmux extension config-dir`/`paths`), or `nil` when not installed.
    func socketPaths(id: String) -> [String: Any]? {
        guard let installed = store.installedExtension(id: id) else { return nil }
        return [
            "id": id,
            "root": installed.rootDirectory.path,
            "config_dir": directories.configDirectory(id: id).path,
            "state_dir": directories.stateDirectory(id: id).path,
            "logs_dir": directories.logsDirectory(id: id).path,
        ]
    }

    private func expireStaleSocketPreviews() {
        let cutoff = Date().addingTimeInterval(-Self.socketPreviewLifetime)
        let expiredTokens = socketPreviewGrants.filter { $0.value.createdAt < cutoff }.map(\.key)
        for token in expiredTokens {
            if let grant = socketPreviewGrants.removeValue(forKey: token) {
                store.discard(grant.preview)
            }
        }
    }

    private func performReportingErrors(
        _ body: @escaping @MainActor (DockExtensionsStore) async throws -> Void
    ) {
        Task { @MainActor in
            do {
                try await body(store)
                settingsState?.lastErrorMessage = nil
            } catch {
                settingsState?.lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// Re-arming observation loop keeping the Settings rows mirrored from the
    /// store (`installed` + `busyExtensionIds` are the tracked reads).
    private func mirrorStore(into state: ExtensionsSettingsState) {
        withObservationTracking {
            state.rows = Self.rows(from: store.installed, busyIds: store.busyExtensionIds)
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.mirrorStore(into: state)
            }
        }
    }

    private static func rows(
        from installed: [InstalledDockExtension],
        busyIds: Set<String>
    ) -> [ExtensionsSettingsState.Row] {
        installed.map { installedExtension in
            let detail: String
            if installedExtension.isLinked {
                detail = String(localized: "extensions.detail.linked", defaultValue: "Linked (dev)")
            } else if let sha = installedExtension.record.pinnedSha {
                detail = String(sha.prefix(7))
            } else {
                detail = ""
            }
            let statusMessage: String?
            switch installedExtension.status {
            case .ok:
                statusMessage = nil
            case .manifestUnavailable(let message):
                statusMessage = message
            case .needsReconsent:
                statusMessage = String(
                    localized: "extensions.status.needsReconsent",
                    defaultValue: "Changed on disk — update to review and re-approve"
                )
            }
            return ExtensionsSettingsState.Row(
                id: installedExtension.id,
                displayName: installedExtension.displayName,
                version: installedExtension.manifest?.version,
                sourceLabel: installedExtension.record.source.description,
                detail: detail,
                iconSystemName: installedExtension.iconSystemName,
                enabled: installedExtension.record.enabled,
                isLinked: installedExtension.isLinked,
                statusMessage: statusMessage,
                isBusy: busyIds.contains(installedExtension.id),
                panes: installedExtension.launchablePanes.map { pane in
                    ExtensionsSettingsState.PaneRow(
                        id: DockExtensionPane.qualifiedId(
                            extensionId: installedExtension.id,
                            paneId: pane.id
                        ),
                        title: pane.title
                    )
                },
                repoURL: installedExtension.record.source.webURL
            )
        }
    }
}
