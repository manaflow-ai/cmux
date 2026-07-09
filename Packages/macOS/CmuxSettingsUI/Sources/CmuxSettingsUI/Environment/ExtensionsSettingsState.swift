import Foundation
import Observation

/// Host-populated view state for the **Extensions** settings section (Dock
/// TUI extensions installed from GitHub).
///
/// Follows the ``SettingsHostActions/sleepyModeStore()`` pattern: the package
/// defines the observable state type, the host owns one instance, fills it
/// from its extensions domain, and vends it through
/// ``SettingsHostActions/dockExtensionsSettingsState()``. Rows are immutable
/// value snapshots plus closure actions — the section never holds a reference
/// into the host's domain stores (snapshot-boundary rule).
@MainActor
@Observable
public final class ExtensionsSettingsState {
    /// One launchable pane of an installed extension.
    public struct PaneRow: Identifiable, Equatable, Sendable {
        /// Qualified `<extensionId>.<paneId>` id.
        public let id: String
        /// Pane title shown in the Open menu.
        public let title: String

        /// Creates a pane row.
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// One installed extension as rendered in Settings.
    public struct Row: Identifiable, Equatable, Sendable {
        /// The extension id.
        public let id: String
        /// Manifest display name (or the id when the manifest is unreadable).
        public let displayName: String
        /// Manifest version string, when readable.
        public let version: String?
        /// Source label (`owner/repo[/subdir]` or the linked path).
        public let sourceLabel: String
        /// Short pin/status detail: abbreviated commit, "Linked", or empty.
        public let detail: String
        /// SF Symbol for the row.
        public let iconSystemName: String
        /// Whether the extension's panes are offered in launchers.
        public let enabled: Bool
        /// Whether this is a linked local development extension.
        public let isLinked: Bool
        /// Blocking problem to surface (unreadable manifest, needs
        /// re-consent), or `nil` when healthy.
        public let statusMessage: String?
        /// Whether an install/update/uninstall for this id is in flight.
        public let isBusy: Bool
        /// Launchable panes (empty when disabled or unhealthy).
        public let panes: [PaneRow]
        /// The GitHub page for the source, when it has one.
        public let repoURL: URL?

        /// Creates a row snapshot.
        public init(
            id: String,
            displayName: String,
            version: String?,
            sourceLabel: String,
            detail: String,
            iconSystemName: String,
            enabled: Bool,
            isLinked: Bool,
            statusMessage: String?,
            isBusy: Bool,
            panes: [PaneRow],
            repoURL: URL?
        ) {
            self.id = id
            self.displayName = displayName
            self.version = version
            self.sourceLabel = sourceLabel
            self.detail = detail
            self.iconSystemName = iconSystemName
            self.enabled = enabled
            self.isLinked = isLinked
            self.statusMessage = statusMessage
            self.isBusy = isBusy
            self.panes = panes
            self.repoURL = repoURL
        }
    }

    /// Closure bundle the host wires to its extensions domain. All closures
    /// run on the main actor.
    public struct Actions {
        /// Re-projects the installed set from disk.
        public var refresh: () -> Void
        /// Starts the consent/install flow for `owner/repo[/subdir]` input.
        public var installFromInput: (String) -> Void
        /// Opens a pane by qualified `<extensionId>.<paneId>` id.
        public var openPane: (String) -> Void
        /// Enables/disables an extension by id.
        public var setEnabled: (String, Bool) -> Void
        /// Starts the consent/update flow for an extension id.
        public var update: (String) -> Void
        /// Uninstalls an extension by id (the section confirms first).
        public var uninstall: (String) -> Void
        /// Opens the community marketplace page.
        public var browseMarketplace: () -> Void

        /// Creates an action bundle; defaults are no-ops for previews/tests.
        public init(
            refresh: @escaping () -> Void = {},
            installFromInput: @escaping (String) -> Void = { _ in },
            openPane: @escaping (String) -> Void = { _ in },
            setEnabled: @escaping (String, Bool) -> Void = { _, _ in },
            update: @escaping (String) -> Void = { _ in },
            uninstall: @escaping (String) -> Void = { _ in },
            browseMarketplace: @escaping () -> Void = {}
        ) {
            self.refresh = refresh
            self.installFromInput = installFromInput
            self.openPane = openPane
            self.setEnabled = setEnabled
            self.update = update
            self.uninstall = uninstall
            self.browseMarketplace = browseMarketplace
        }
    }

    /// The installed extensions, in lockfile order.
    public var rows: [Row]

    /// Human-readable failure from the most recent operation, cleared on the
    /// next successful one.
    public var lastErrorMessage: String?

    /// Host-wired actions.
    public var actions: Actions

    /// Creates state; hosts fill `rows`/`actions`, previews use the defaults.
    public init(
        rows: [Row] = [],
        lastErrorMessage: String? = nil,
        actions: Actions = Actions()
    ) {
        self.rows = rows
        self.lastErrorMessage = lastErrorMessage
        self.actions = actions
    }
}
