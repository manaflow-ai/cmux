import Bonsplit
import CMUXAgentLaunch
import CmuxFoundation
import CmuxWorkspaces
import Combine
import Foundation
import Observation
import CmuxSettings

// `CodingUserInfoKey.cmuxWorkspaceColorDefaults` (and the new
// `.cmuxWorkspaceColorResolver` color-decode seam) are owned by CmuxWorkspaces
// alongside `CmuxWorkspaceDefinition`, reached through `import CmuxWorkspaces`.

struct CmuxConfigFile: Codable, Sendable {
    var actions: [String: CmuxConfigActionDefinition]
    var ui: CmuxConfigUIDefinition?
    var notifications: CmuxNotificationConfigDefinition?
    var newWorkspaceCommand: String?
    var surfaceTabBarButtons: [CmuxSurfaceTabBarButton]?
    var commands: [CmuxCommandDefinition]
    var vault: CmuxVaultConfigDefinition?
    var workspaceGroups: CmuxConfigWorkspaceGroupsDefinition?

    private enum CodingKeys: String, CodingKey {
        case actions, ui, notifications, newWorkspaceCommand, surfaceTabBarButtons, commands, vault, workspaceGroups
    }

    init(
        actions: [String: CmuxConfigActionDefinition] = [:],
        ui: CmuxConfigUIDefinition? = nil,
        notifications: CmuxNotificationConfigDefinition? = nil,
        newWorkspaceCommand: String? = nil,
        surfaceTabBarButtons: [CmuxSurfaceTabBarButton]? = nil,
        commands: [CmuxCommandDefinition] = [],
        vault: CmuxVaultConfigDefinition? = nil,
        workspaceGroups: CmuxConfigWorkspaceGroupsDefinition? = nil
    ) {
        self.actions = actions
        self.ui = ui
        self.notifications = notifications
        self.newWorkspaceCommand = newWorkspaceCommand
        self.surfaceTabBarButtons = surfaceTabBarButtons
        self.commands = commands
        self.vault = vault
        self.workspaceGroups = workspaceGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedActions = try container.decodeIfPresent(
            [String: CmuxConfigActionDefinition].self,
            forKey: .actions
        ) ?? [:]
        actions = try Self.normalizedActions(
            decodedActions,
            codingPath: decoder.codingPath + [CodingKeys.actions]
        )
        ui = try container.decodeIfPresent(CmuxConfigUIDefinition.self, forKey: .ui)
        notifications = try container.decodeIfPresent(CmuxNotificationConfigDefinition.self, forKey: .notifications)

        if let rawNewWorkspaceCommand = try container.decodeIfPresent(String.self, forKey: .newWorkspaceCommand) {
            let trimmed = rawNewWorkspaceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.newWorkspaceCommand],
                        debugDescription: "newWorkspaceCommand must not be blank"
                    )
                )
            }
            newWorkspaceCommand = trimmed
        } else {
            newWorkspaceCommand = nil
        }

        let rootSurfaceButtons = try container.decodeIfPresent(
            [CmuxSurfaceTabBarButton].self,
            forKey: .surfaceTabBarButtons
        )
        let configuredSurfaceButtons = ui?.surfaceTabBar?.buttons ?? rootSurfaceButtons
        if let configuredSurfaceButtons {
            surfaceTabBarButtons = try Self.validatedSurfaceTabBarButtons(
                configuredSurfaceButtons,
                codingPath: decoder.codingPath + [
                    ui?.surfaceTabBar?.buttons == nil ? CodingKeys.surfaceTabBarButtons : CodingKeys.ui
                ]
            )
        } else {
            surfaceTabBarButtons = nil
        }
        commands = try container.decodeIfPresent([CmuxCommandDefinition].self, forKey: .commands) ?? []
        vault = try container.decodeIfPresent(CmuxVaultConfigDefinition.self, forKey: .vault)
        workspaceGroups = try container.decodeIfPresent(
            CmuxConfigWorkspaceGroupsDefinition.self,
            forKey: .workspaceGroups
        )
    }

    private static func normalizedActions(
        _ decodedActions: [String: CmuxConfigActionDefinition],
        codingPath: [CodingKey]
    ) throws -> [String: CmuxConfigActionDefinition] {
        var actions: [String: CmuxConfigActionDefinition] = [:]
        var canonicalIDs: [String: String] = [:]
        for (rawID, action) in decodedActions {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions keys must not be blank"
                    )
                )
            }
            if actions[id] != nil {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate ids"
                    )
                )
            }
            let canonicalID = CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
            if let existingID = canonicalIDs[canonicalID] {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate aliases for '\(canonicalID)' (found '\(existingID)' and '\(id)')"
                    )
                )
            }
            canonicalIDs[canonicalID] = id
            actions[id] = action
        }
        return actions
    }

    private static func validatedSurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        codingPath: [CodingKey]
    ) throws -> [CmuxSurfaceTabBarButton] {
        var seen = Set<String>()
        for button in buttons {
            if !seen.insert(button.id).inserted {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "surface tab bar buttons must not contain duplicate ids"
                    )
                )
            }
        }
        return buttons
    }
}

/// Per-cwd customization for sidebar workspace groups. Keyed by the anchor
/// workspace's cwd. Keys containing `*` or `?` are matched as fnmatch globs;
/// otherwise they are path prefixes. Longest match wins. `~` is expanded.
struct CmuxConfigWorkspaceGroupsDefinition: Codable, Sendable, Equatable {
    var byCwd: [String: CmuxConfigWorkspaceGroupEntry]?

    enum CodingKeys: String, CodingKey {
        case byCwd
    }
}

struct CmuxConfigWorkspaceGroupEntry: Codable, Sendable, Equatable {
    var color: String?
    var icon: String?
    var contextMenu: [CmuxConfigContextMenuItem]?
    /// Where a newly-created workspace lands inside the group when the user
    /// clicks the header's `+` button or invokes Cmd-N from a group member.
    /// Valid values: `"afterCurrent"` (after the current in-group workspace,
    /// falling back to top), `"top"` (immediately after the anchor), or
    /// `"end"` (after the last member). When omitted,
    /// falls back to the global default
    /// (the stored `workspaceGroups.newWorkspacePlacement` setting).
    var newWorkspacePlacement: String?
}

/// Resolved snapshot of a per-cwd workspace group entry, with the JSON key
/// normalized for matching and any `contextMenu` actions resolved against the
/// loaded action/command tables.
struct CmuxResolvedWorkspaceGroupConfig: Sendable, Equatable {
    let originalKey: String
    let normalizedKey: String
    let isGlob: Bool
    let color: String?
    let iconSymbol: String?
    let contextMenuItems: [CmuxResolvedConfigContextMenuItem]
    /// Parsed override for where the `+` button places its new workspace.
    /// nil means "fall through to the global default."
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
}

// CmuxNotificationHooksMode, CmuxNotificationConfigDefinition, and
// CmuxNotificationHookDefinition moved to
// CmuxFoundation/ConfigValues/. Consumers reach them via `import CmuxFoundation`.
// CmuxResolvedNotificationHook stays app-side: it references the app-domain
// CmuxActionTrustDescriptor (cross-slice-blocked).

struct CmuxResolvedNotificationHook: Sendable, Hashable {
    let id: String
    let command: String
    let timeoutSeconds: TimeInterval
    let sourcePath: String?
    let cwd: String
    let trustDescriptor: CmuxActionTrustDescriptor?

    init(
        id: String,
        command: String,
        timeoutSeconds: TimeInterval,
        sourcePath: String?,
        cwd: String,
        trustDescriptor: CmuxActionTrustDescriptor? = nil
    ) {
        self.id = id
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.sourcePath = sourcePath
        self.cwd = cwd
        self.trustDescriptor = trustDescriptor
    }

    static func == (lhs: CmuxResolvedNotificationHook, rhs: CmuxResolvedNotificationHook) -> Bool {
        lhs.id == rhs.id &&
            lhs.command == rhs.command &&
            lhs.timeoutSeconds == rhs.timeoutSeconds &&
            lhs.sourcePath == rhs.sourcePath &&
            lhs.cwd == rhs.cwd &&
            lhs.trustDescriptor?.fingerprint == rhs.trustDescriptor?.fingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(command)
        hasher.combine(timeoutSeconds)
        hasher.combine(sourcePath)
        hasher.combine(cwd)
        hasher.combine(trustDescriptor?.fingerprint)
    }
}

// CmuxConfigTerminalCommandTarget and CmuxConfigAgentKind (+ its Codable
// conformance) moved to CmuxWorkspaces/CustomLayout; reached via
// `import CmuxWorkspaces` (already imported above).

// The `cmux.json` action wire-schema cluster
// (CmuxConfigActionDefinition / CmuxSurfaceTabBarButton with its
// WorkspaceSurfaceTabBarButtonResolvable conformance / CmuxResolvedConfigAction)
// now lives in CmuxWorkspaces/CustomLayout/, co-located with the
// CmuxButtonIcon/CmuxSurfaceTabBarButtonAction/CmuxSurfaceTabBarBuiltInAction
// value types it builds on. They are reached through `import CmuxWorkspaces`.
typealias CmuxConfigActionDefinition = CmuxWorkspaces.CmuxConfigActionDefinition
typealias CmuxSurfaceTabBarButton = CmuxWorkspaces.CmuxSurfaceTabBarButton
typealias CmuxResolvedConfigAction = CmuxWorkspaces.CmuxResolvedConfigAction

extension CmuxResolvedConfigAction.BuiltInStrings {
    /// The built-in and agent default titles resolved against the app bundle, so
    /// `String(localized:)` keeps the Japanese catalog when the resolved actions
    /// move through CmuxWorkspaces. The package cannot call `String(localized:)`
    /// itself (it would bind to the package bundle and drop every translation).
    static var appBundle: CmuxResolvedConfigAction.BuiltInStrings {
        CmuxResolvedConfigAction.BuiltInStrings(
            newWorkspace: String(localized: "command.newWorkspace.title", defaultValue: "New Workspace"),
            cloudVM: String(localized: "command.cloudVM.title", defaultValue: "Start Cloud VM"),
            newTerminal: String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab"),
            newBrowser: String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Tab"),
            splitRight: String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right"),
            splitDown: String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down"),
            builtInSubtitle: String(localized: "command.cmuxConfig.builtInSubtitle", defaultValue: "cmux"),
            codex: String(localized: "command.cmuxConfig.defaultCodexTitle", defaultValue: "Codex"),
            claudeCode: String(localized: "command.cmuxConfig.defaultClaudeCodeTitle", defaultValue: "Claude Code")
        )
    }
}

// `CmuxCommandDefinition` (a `command` block in `cmux.json`) and its restart
// behavior `CmuxRestartBehavior` now live in CmuxWorkspaces/CustomLayout/,
// co-located with the layout/workspace wire schema they reference. They are
// reached through `import CmuxWorkspaces`.
typealias CmuxCommandDefinition = CmuxWorkspaces.CmuxCommandDefinition
typealias CmuxRestartBehavior = CmuxWorkspaces.CmuxRestartBehavior

// The `cmux.json` layout wire-schema cluster (CmuxLayoutNode / CmuxSplitDefinition
// / CmuxSplitDirection / CmuxPaneDefinition / CmuxSurfaceDefinition /
// CmuxSurfaceType), the CmuxLayoutNode -> WorkspaceCustomLayoutNode bridge, and
// CmuxWorkspaceDefinition now live in CmuxWorkspaces/CustomLayout/, co-located
// with the canonical WorkspaceCustomLayoutNode/WorkspaceCustomSurface value image
// they map onto. They are reached through `import CmuxWorkspaces`.

// `CmuxResolvedCommand` (a `CmuxCommandDefinition` paired with its `cmux.json`
// source path) now lives in CmuxWorkspaces/CustomLayout/, reached through
// `import CmuxWorkspaces`.
typealias CmuxResolvedCommand = CmuxWorkspaces.CmuxResolvedCommand

// CmuxConfigIssue (+ its nested Kind) now lives in
// CmuxFoundation/ConfigValues/CmuxConfigIssue.swift, reached through
// `import CmuxFoundation` (already imported above).

/// Per-window resolved-configuration model: parses the global + local
/// `cmux.json` hierarchy, exposes the resolved commands/actions/menus/hooks to
/// SwiftUI, and re-resolves on config-file changes and `CmuxActionTrust`
/// updates.
///
/// **Isolation design.** `@MainActor` because every writer of the observed
/// state runs on the main actor: the `loadAll()` resolution path, the
/// `wireDirectoryTracking`/`repointDirectoryTracking` selection glue, and all
/// file-watch handlers hop to main before mutating. State lives where its
/// callers (SwiftUI views in the same window, the reload coordinator) live, so
/// no cross-actor bridge is needed for the model itself.
///
/// **Observation surface.** `@Observable` (not `ObservableObject`) so SwiftUI
/// tracks the resolved outputs through Observation; the migration direction is
/// `ObservableObject`/`@Published` → `@Observable`. The previously `@Published`
/// properties (`loadedCommands` … `configRevision`) stay observed stored
/// properties; every other stored property is internal machinery and is marked
/// `@ObservationIgnored` so the observable surface is exactly the formerly
/// `@Published` set (under `ObservableObject` only those fired
/// `objectWillChange`; under `@Observable` an un-ignored stored var would
/// become observable, which would widen the surface and change view-tracking
/// behavior).
///
/// **Preserved machinery.** The file-watch / NotificationCenter plumbing is
/// unchanged by this cutover: the weak `tabManager` reference, the
/// `WorkspacesObservation` selection/tabs watches, the per-source local /
/// global / hook `DispatchSource` + `CmuxFileWatch.FileWatcher` watchers, the
/// `CmuxActionTrust.didChangeNotification` Combine sink, and
/// `lifetimeCancellables`/`trackingCancellables`. Only the property-observation
/// mechanism changed.
@MainActor
@Observable
final class CmuxConfigStore {
    private static let defaultNewWorkspaceContextMenu: [CmuxConfigContextMenuItem] = [
        .action(CmuxConfigContextMenuActionItem(action: CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID)),
        .action(CmuxConfigContextMenuActionItem(action: CmuxSurfaceTabBarBuiltInAction.cloudVM.configID)),
    ]

    private(set) var loadedCommands: [CmuxCommandDefinition] = []
    private(set) var loadedActions: [CmuxResolvedConfigAction] = []
    private(set) var newWorkspaceCommandName: String?
    private(set) var newWorkspaceActionID: String?
    private(set) var newWorkspaceContextMenuItems: [CmuxResolvedConfigContextMenuItem] = []
    /// Resolved per-cwd workspace group customization, keyed by the JSON cwd key.
    /// Use `resolveWorkspaceGroupConfig(forCwd:)` to find the best match for an
    /// anchor workspace's cwd. Empty when no `workspaceGroups.byCwd` block is
    /// configured.
    private(set) var workspaceGroupConfigs: [CmuxResolvedWorkspaceGroupConfig] = []
    private(set) var surfaceTabBarButtons: [CmuxSurfaceTabBarButton] = CmuxSurfaceTabBarButton.defaults
    private(set) var notificationHooks: [CmuxResolvedNotificationHook] = []
    private(set) var configurationIssues: [CmuxConfigIssue] = []
    private(set) var configRevision: UInt64 = 0

    /// Which config file each command came from, keyed by command id.
    @ObservationIgnored
    private(set) var commandSourcePaths: [String: String] = [:]
    @ObservationIgnored
    private(set) var actionLookup: [String: CmuxResolvedConfigAction] = [:]
    @ObservationIgnored
    private(set) var surfaceTabBarButtonSourcePath: String?
    @ObservationIgnored
    private(set) var surfaceTabBarCommandSourcePaths: [String: String] = [:]
    @ObservationIgnored
    private(set) var newWorkspaceActionSourcePath: String?

    @ObservationIgnored
    private(set) var localConfigPath: String?
    @ObservationIgnored
    private weak var tabManager: TabManager?
    let globalConfigPath: String
    @ObservationIgnored
    private let fileWatchingEnabled: Bool

    nonisolated private static func defaultGlobalConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
    }

    private struct ActionEntry {
        let definition: CmuxConfigActionDefinition
        let sourcePath: String?
    }

    private struct ResolvedSurfaceTabBarButtonEntry {
        let button: CmuxSurfaceTabBarButton
        let terminalCommandSourcePath: String?
    }

    private struct ResolvedSurfaceTabBarButtons {
        let buttons: [CmuxSurfaceTabBarButton]
        let terminalCommandSourcePaths: [String: String]
    }

    private struct ResolvedContextMenuItems {
        let items: [CmuxResolvedConfigContextMenuItem]
        let issues: [CmuxConfigIssue]
    }

    private struct NewWorkspaceCommandResolution {
        let command: CmuxResolvedCommand?
        let issue: CmuxConfigIssue?
    }

    private struct NewWorkspaceActionResolution {
        let action: CmuxResolvedConfigAction?
        let command: CmuxResolvedCommand?
        let issue: CmuxConfigIssue?
    }

    private struct ParsedConfigCacheEntry {
        let fileSize: UInt64
        let modificationDate: Date?
        let workspaceColorPaletteFingerprint: String
        let config: CmuxConfigFile?
        let issue: CmuxConfigIssue?
    }

    private struct ParsedConfigResult {
        let config: CmuxConfigFile?
        let issue: CmuxConfigIssue?
    }

    @ObservationIgnored
    private var surfaceTabBarWorkspaceCommands: [String: CmuxResolvedCommand] = [:]
    @ObservationIgnored
    private var resolvedNewWorkspaceCommandCache: CmuxResolvedCommand?
    @ObservationIgnored
    private var resolvedNewWorkspaceActionCache: CmuxResolvedConfigAction?
    @ObservationIgnored
    private var parsedConfigCache: [String: ParsedConfigCacheEntry] = [:]
    /// Formats `cmux.json` schema-decoding failures into `CmuxConfigIssue`
    /// diagnostics (lifted out of this store into `CmuxFoundation`).
    @ObservationIgnored
    private let schemaErrorFormatter = CmuxConfigSchemaErrorFormatter()
    @ObservationIgnored
    private var lifetimeCancellables = Set<AnyCancellable>()
    @ObservationIgnored
    private var trackingCancellables = Set<AnyCancellable>()
    /// `@Observable` watches on the `WorkspacesModel` (selection + tabs),
    /// replacing the retired `selectedTabIdPublisher` / `tabsPublisher` Combine
    /// bridges. The directory subscription on the *selected* workspace's
    /// `$surfaceTabBarDirectory` (a `Workspace` `@Published`, out of this slice's
    /// scope) stays Combine and is re-pointed whenever the selected workspace id
    /// changes, hand-rolling the former `switchToLatest`.
    @ObservationIgnored
    private var selectionObservation: WorkspacesObservation?
    @ObservationIgnored
    private var tabsObservation: WorkspacesObservation?
    @ObservationIgnored
    private var trackedSelectedWorkspaceId: UUID?
    @ObservationIgnored
    private var trackedDirectoryCancellable: AnyCancellable?
    @ObservationIgnored
    private var lastTrackedDirectory: String??
    // The local config still uses a bespoke DispatchSource watcher because it
    // performs search-directory *path re-resolution* (not just reload-on-change).
    // The global config and hook files use CmuxFileWatch.FileWatcher.
    @ObservationIgnored
    private var localFileWatchSource: DispatchSourceFileSystemObject?
    @ObservationIgnored
    private var localFileDescriptor: Int32 = -1
    @ObservationIgnored
    private var localConfigSearchDirectory: String?
    @ObservationIgnored
    private var hookWatchers: [String: FileWatcher] = [:]
    @ObservationIgnored
    private var hookWatchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var localFallbackDirectoryWatchSource: DispatchSourceFileSystemObject?
    @ObservationIgnored
    private var localFallbackDirectoryDescriptor: Int32 = -1
    @ObservationIgnored
    private var globalWatcher: FileWatcher?
    @ObservationIgnored
    private var globalWatchTask: Task<Void, Never>?
    @ObservationIgnored
    private let watchQueue = DispatchQueue(label: "com.cmux.config-file-watch")

    private static let maxReattachAttempts = 5
    private static let reattachDelay: TimeInterval = 0.5

    /// Pure path discovery + canonicalization for the project-local `cmux.json`,
    /// extracted to ``CmuxLocalConfigPathResolver`` in CmuxFoundation. The store
    /// owns one instance and forwards through it so call sites stay byte-identical.
    @ObservationIgnored
    private let localConfigPathResolver = CmuxLocalConfigPathResolver()

    init(
        globalConfigPath: String = CmuxConfigStore.defaultGlobalConfigPath(),
        localConfigPath: String? = nil,
        startFileWatchers: Bool = false
    ) {
        self.globalConfigPath = globalConfigPath
        self.localConfigPath = localConfigPath
        self.fileWatchingEnabled = startFileWatchers
        self.localConfigSearchDirectory = localConfigPath.map(localConfigPathResolver.searchDirectory(forLocalConfigPath:))
        NotificationCenter.default.publisher(for: CmuxActionTrust.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.loadAll()
            }
            .store(in: &lifetimeCancellables)
        if startFileWatchers {
            if localConfigPath != nil {
                startLocalFileWatcher()
            }
            startGlobalWatching()
        }
    }

    deinit {
        localFileWatchSource?.cancel()
        localFallbackDirectoryWatchSource?.cancel()
        hookWatchTasks.values.forEach { $0.cancel() }
        globalWatchTask?.cancel()
    }

    // MARK: - Public API

    func wireDirectoryTracking(tabManager: TabManager) {
        trackingCancellables.removeAll()
        selectionObservation?.cancel()
        tabsObservation?.cancel()
        trackedDirectoryCancellable?.cancel()
        trackedDirectoryCancellable = nil
        trackedSelectedWorkspaceId = nil
        lastTrackedDirectory = nil
        self.tabManager = tabManager

        // Selection watch: when the selected workspace id changes (the former
        // `compactMap`+`removeDuplicates(by:id)`), re-point the directory
        // subscription onto the new workspace's `$surfaceTabBarDirectory`
        // (the former `map`+`switchToLatest`). Observation does not replay, so
        // the explicit `updateLocalConfigPath(...)` below seeds the initial path
        // just as the bridge's replay did.
        selectionObservation = tabManager.workspaces.observeSelectedTabId { [weak self] in
            self?.repointDirectoryTracking()
        }
        repointDirectoryTracking()

        tabsObservation = tabManager.workspaces.observeTabs { [weak self] in
            self?.applySurfaceTabBarButtonsToCurrentManager()
        }
        // `tabsPublisher` replayed its current value to the former `.sink` on
        // subscribe; observation does not, so run the apply once now.
        applySurfaceTabBarButtonsToCurrentManager()

        updateLocalConfigPath(tabManager.selectedWorkspace?.surfaceTabBarDirectory)
    }

    /// Hand-rolls the former `selectedTabIdPublisher`→workspace→`$surfaceTabBarDirectory`
    /// `switchToLatest` chain: resolves the currently selected workspace, and if
    /// its id differs from the tracked one, tears down the old directory
    /// subscription and subscribes to the new workspace's `$surfaceTabBarDirectory`.
    /// The inner `.removeDuplicates()` on directory values is reproduced via
    /// `lastTrackedDirectory`.
    private func repointDirectoryTracking() {
        guard let tabManager else { return }
        let selectedId = tabManager.selectedTabId
        let workspace = selectedId.flatMap { id in tabManager.tabs.first(where: { $0.id == id }) }
        // `compactMap` dropped a nil selection: keep the existing subscription
        // when there is no selected workspace, matching the former chain which
        // emitted nothing (never tore down) on a nil/absent selection.
        guard let workspace else { return }
        guard workspace.id != trackedSelectedWorkspaceId else { return }
        trackedSelectedWorkspaceId = workspace.id
        trackedDirectoryCancellable?.cancel()
        // Do NOT reset `lastTrackedDirectory` across the switch: the former
        // `.switchToLatest().removeDuplicates()` deduped consecutive values over
        // the merged stream, so a switch to a workspace whose current directory
        // equals the previous workspace's last directory was suppressed. Carrying
        // `lastTrackedDirectory` reproduces that cross-switch dedup.
        trackedDirectoryCancellable = workspace.surfaceTabBarDirectoryPublisher
            .sink { [weak self] directory in
                guard let self else { return }
                // Reproduce the inner `.removeDuplicates()`.
                if let last = self.lastTrackedDirectory, last == directory { return }
                self.lastTrackedDirectory = .some(directory)
                self.updateLocalConfigPath(directory)
            }
    }

    func notificationHooks(startingFrom directory: String?) -> [CmuxResolvedNotificationHook] {
        let globalConfig = parseConfig(at: globalConfigPath).config
        let localConfigs: [(path: String, config: CmuxConfigFile)]
        if let directory, !directory.isEmpty {
            localConfigs = findCmuxConfigHierarchy(startingFrom: directory).compactMap { path in
                parseConfig(at: path).config.map { (path: path, config: $0) }
            }
        } else {
            localConfigs = []
        }
        return resolveNotificationHooks(
            globalConfig: globalConfig,
            localConfigs: localConfigs
        )
    }

    private func updateLocalConfigPath(_ directory: String?) {
        let newPath: String?
        if let directory, !directory.isEmpty {
            localConfigSearchDirectory = directory
            newPath = resolvedLocalConfigPath(startingFrom: directory)
        } else {
            localConfigSearchDirectory = nil
            newPath = nil
        }

        guard newPath != localConfigPath else { return }
        stopLocalFileWatcher()
        localConfigPath = newPath
        if fileWatchingEnabled, newPath != nil {
            startLocalFileWatcher()
        }
        loadAll()
    }

    private func resolvedLocalConfigPath(startingFrom directory: String) -> String {
        localConfigPathResolver.resolvedLocalConfigPath(startingFrom: directory)
    }

    private func findCmuxConfigHierarchy(startingFrom directory: String) -> [String] {
        localConfigPathResolver.findCmuxConfigHierarchy(startingFrom: directory)
    }

    func loadAll() {
        var commands: [CmuxCommandDefinition] = []
        var seenNames = Set<String>()
        var sourcePaths: [String: String] = [:]
        var configuredNewWorkspaceCommandName: String?
        var configuredNewWorkspaceCommandSourcePath: String?
        var configuredNewWorkspaceActionID: String?
        var configuredNewWorkspaceActionSourcePath: String?
        var configuredNewWorkspaceContextMenu: [CmuxConfigContextMenuItem]?
        var configuredNewWorkspaceContextMenuSourcePath: String?
        var configuredSurfaceTabBarButtons: [CmuxSurfaceTabBarButton]?
        var configuredSurfaceTabBarButtonSourcePath: String?
        let localPath = localConfigPath
        let localParseResult = localPath.map { parseConfig(at: $0) }
        let globalParseResult = parseConfig(at: globalConfigPath)
        let localConfig = localParseResult?.config
        let globalConfig = globalParseResult.config
        let localHookPaths = resolvedLocalNotificationHookPaths(fallbackLocalPath: localPath)
        let localHookParseResults = localHookPaths.map { path in
            (path: path, result: parseConfig(at: path))
        }
        var issues = [CmuxConfigIssue]()
        if let issue = localParseResult?.issue {
            issues.append(issue)
        }
        if let issue = globalParseResult.issue {
            issues.append(issue)
        }
        for hookParseResult in localHookParseResults {
            guard hookParseResult.path != localPath,
                  let issue = hookParseResult.result.issue else { continue }
            issues.append(issue)
        }
        let localActions = localConfig.map { actionEntries(from: $0.actions, sourcePath: localPath) } ?? [:]
        let globalActions = globalConfig.map { actionEntries(from: $0.actions, sourcePath: globalConfigPath) } ?? [:]

        // Local config takes precedence
        if let localConfig {
            if let newWorkspaceActionID = localConfig.ui?.newWorkspace?.action {
                configuredNewWorkspaceActionID = newWorkspaceActionID
                configuredNewWorkspaceActionSourcePath = localPath
            }
            if let contextMenu = localConfig.ui?.newWorkspace?.contextMenu {
                configuredNewWorkspaceContextMenu = contextMenu
                configuredNewWorkspaceContextMenuSourcePath = localPath
            }
            if configuredNewWorkspaceActionID == nil,
               let newWorkspaceCommand = localConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = newWorkspaceCommand
                configuredNewWorkspaceCommandSourcePath = localPath
            }
            if let buttons = localConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = buttons
                configuredSurfaceTabBarButtonSourcePath = localPath
            }
            for command in localConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    if let localPath {
                        sourcePaths[command.id] = localPath
                    }
                }
            }
        }

        // Global config fills in the rest
        if let globalConfig {
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceActionID = globalConfig.ui?.newWorkspace?.action {
                configuredNewWorkspaceActionID = newWorkspaceActionID
                configuredNewWorkspaceActionSourcePath = globalConfigPath
            }
            if configuredNewWorkspaceContextMenu == nil,
               let contextMenu = globalConfig.ui?.newWorkspace?.contextMenu {
                configuredNewWorkspaceContextMenu = contextMenu
                configuredNewWorkspaceContextMenuSourcePath = globalConfigPath
            }
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceCommand = globalConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = newWorkspaceCommand
                configuredNewWorkspaceCommandSourcePath = globalConfigPath
            }
            if configuredSurfaceTabBarButtons == nil,
               let buttons = globalConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = buttons
                configuredSurfaceTabBarButtonSourcePath = globalConfigPath
            }
            for command in globalConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    sourcePaths[command.id] = globalConfigPath
                }
            }
        }

        let resolvedActions = resolvedActionRegistry(
            globalActions: globalActions,
            localActions: localActions,
            commands: commands,
            commandSourcePaths: sourcePaths
        )
        let resolvedActionLookup = Dictionary(uniqueKeysWithValues: resolvedActions.map { ($0.id, $0) })
        let configuredButtons = configuredSurfaceTabBarButtons ?? CmuxSurfaceTabBarButton.defaults
        let defaultResolvedButtons = (try? CmuxSurfaceTabBarButton.defaults.map {
            try $0.resolved(actions: resolvedActionLookup, codingPath: [])
        }) ?? [
            .builtIn(.newTerminal),
            .builtIn(.newBrowser),
            .builtIn(.splitRight),
            .builtIn(.splitDown)
        ]
        let resolvedButtons = resolvedSurfaceTabBarButtons(
            configuredButtons,
            actions: resolvedActionLookup,
            settingName: "ui.surfaceTabBar.buttons"
        ) ?? ResolvedSurfaceTabBarButtons(
            buttons: defaultResolvedButtons,
            terminalCommandSourcePaths: [:]
        )
        let resolvedWorkspaceButtons = resolvedSurfaceTabBarWorkspaceCommands(
            resolvedButtons.buttons,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNewWorkspaceAction = resolvedConfiguredNewWorkspaceAction(
            actionID: configuredNewWorkspaceActionID,
            actionSourcePath: configuredNewWorkspaceActionSourcePath,
            commandName: configuredNewWorkspaceCommandName,
            commandSourcePath: configuredNewWorkspaceCommandSourcePath,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNewWorkspaceContextMenuItems = resolvedConfigContextMenuItems(
            configuredNewWorkspaceContextMenu ?? Self.defaultNewWorkspaceContextMenu,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths,
            settingName: "ui.newWorkspace.contextMenu",
            settingSourcePath: configuredNewWorkspaceContextMenuSourcePath
        )
        let resolvedNotificationHooks = resolveNotificationHooks(
            globalConfig: globalConfig,
            localConfigs: localHookParseResults.compactMap { entry in
                entry.result.config.map { (path: entry.path, config: $0) }
            }
        )

        loadedCommands = commands
        loadedActions = resolvedActions
        commandSourcePaths = sourcePaths
        actionLookup = resolvedActionLookup
        newWorkspaceActionID = configuredNewWorkspaceActionID
        newWorkspaceActionSourcePath = configuredNewWorkspaceActionSourcePath
        newWorkspaceCommandName = configuredNewWorkspaceCommandName
        newWorkspaceContextMenuItems = resolvedNewWorkspaceContextMenuItems.items
        let resolvedGroupConfigs = resolveWorkspaceGroupConfigsFromLayers(
            localConfig: localConfig,
            globalConfig: globalConfig,
            localPath: localPath,
            globalPath: globalConfigPath,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths,
            issues: &issues
        )
        workspaceGroupConfigs = resolvedGroupConfigs
        surfaceTabBarButtonSourcePath = configuredSurfaceTabBarButtonSourcePath
        surfaceTabBarCommandSourcePaths = resolvedButtons.terminalCommandSourcePaths
        surfaceTabBarWorkspaceCommands = resolvedWorkspaceButtons.workspaceCommands
        surfaceTabBarButtons = resolvedWorkspaceButtons.buttons
        notificationHooks = resolvedNotificationHooks
        resolvedNewWorkspaceActionCache = resolvedNewWorkspaceAction.action
        resolvedNewWorkspaceCommandCache = resolvedNewWorkspaceAction.command
        if let issue = resolvedNewWorkspaceAction.issue {
            issues.append(issue)
        }
        issues.append(contentsOf: resolvedNewWorkspaceContextMenuItems.issues)
        configurationIssues = issues
        if fileWatchingEnabled {
            updateLocalHookFileWatchers(
                paths: localHookPaths,
                primaryLocalPath: localPath
            )
        }
        applySurfaceTabBarButtonsToCurrentManager()
        configRevision &+= 1
    }

    private func resolvedLocalNotificationHookPaths(fallbackLocalPath: String?) -> [String] {
        if let searchDirectory = localConfigSearchDirectory {
            var paths = findCmuxConfigHierarchy(startingFrom: searchDirectory)
            if let fallbackLocalPath, !paths.contains(fallbackLocalPath) {
                paths.append(fallbackLocalPath)
            }
            return paths
        }
        return fallbackLocalPath.map { [$0] } ?? []
    }

    private func resolveNotificationHooks(
        globalConfig: CmuxConfigFile?,
        localConfigs: [(path: String, config: CmuxConfigFile)]
    ) -> [CmuxResolvedNotificationHook] {
        var hooks: [CmuxResolvedNotificationHook] = []
        if let globalHooks = globalConfig?.notifications?.hooks {
            hooks.append(contentsOf: resolvedNotificationHooks(
                globalHooks,
                sourcePath: globalConfigPath
            ))
        }

        for entry in localConfigs {
            guard let notifications = entry.config.notifications else { continue }
            if notifications.hooksMode == .replace {
                hooks.removeAll()
            }
            if let localHooks = notifications.hooks {
                hooks.append(contentsOf: resolvedNotificationHooks(
                    localHooks,
                    sourcePath: entry.path
                ))
            }
        }
        return hooks
    }

    private func resolvedNotificationHooks(
        _ definitions: [CmuxNotificationHookDefinition],
        sourcePath: String
    ) -> [CmuxResolvedNotificationHook] {
        let cwd = CmuxConfigImagePath(configSourcePath: sourcePath).projectRoot
        let canonicalSourcePath = localConfigPathResolver.canonicalPath(sourcePath)
        let canonicalGlobalConfigPath = localConfigPathResolver.canonicalPath(globalConfigPath)
        let isGlobalHook = canonicalSourcePath == canonicalGlobalConfigPath
        return definitions.compactMap { definition in
            guard definition.enabled else { return nil }
            let trustDescriptor: CmuxActionTrustDescriptor?
            if isGlobalHook {
                trustDescriptor = nil
            } else {
                trustDescriptor = CmuxActionTrustDescriptor(
                    actionID: definition.id,
                    kind: "notificationHook",
                    command: definition.command,
                    target: "notificationPolicy",
                    workspaceCommand: nil,
                    configPath: canonicalSourcePath,
                    projectRoot: localConfigPathResolver.canonicalPath(cwd),
                    iconFingerprint: nil
                )
            }
            return CmuxResolvedNotificationHook(
                id: definition.id,
                command: definition.command,
                timeoutSeconds: definition.resolvedTimeoutSeconds,
                sourcePath: sourcePath,
                cwd: cwd,
                trustDescriptor: trustDescriptor
            )
        }
    }

    private func actionEntries(
        from actions: [String: CmuxConfigActionDefinition],
        sourcePath: String?
    ) -> [String: ActionEntry] {
        actions.mapValues { ActionEntry(definition: $0, sourcePath: sourcePath) }
    }

    private func mergedActionEntries(
        primary: [String: ActionEntry],
        fallback: [String: ActionEntry]
    ) -> [String: ActionEntry] {
        fallback.merging(primary) { _, primary in primary }
    }

    private func resolvedActionRegistry(
        globalActions: [String: ActionEntry],
        localActions: [String: ActionEntry],
        commands: [CmuxCommandDefinition],
        commandSourcePaths: [String: String]
    ) -> [CmuxResolvedConfigAction] {
        let builtInStrings = CmuxResolvedConfigAction.BuiltInStrings.appBundle
        var registry = Dictionary(
            uniqueKeysWithValues: CmuxSurfaceTabBarBuiltInAction.allCases.map {
                ($0.configID, CmuxResolvedConfigAction.builtIn($0, strings: builtInStrings))
            }
        )

        func apply(_ entries: [String: ActionEntry]) {
            for (id, entry) in entries {
                let registryID = CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
                if let existing = registry[registryID] {
                    guard let resolved = existing.applying(entry.definition, sourcePath: entry.sourcePath) else { continue }
                    registry[registryID] = resolved
                } else if let resolved = CmuxResolvedConfigAction.fromDefinition(
                    id: id,
                    definition: entry.definition,
                    sourcePath: entry.sourcePath,
                    strings: builtInStrings
                ) {
                    registry[id] = resolved
                } else {
                    NSLog("[CmuxConfig] action '%@' ignored because it does not define a runnable action", id)
                }
            }
        }

        apply(globalActions)
        apply(localActions)

        for command in commands where registry[command.id] == nil {
            let sourcePath = commandSourcePaths[command.id]
            registry[command.id] = CmuxResolvedConfigAction(
                id: command.id,
                title: String(
                    localized: "command.cmuxConfig.customTitle",
                    defaultValue: "Custom: \(command.name.sanitizedCmuxConfigText)"
                ),
                subtitle: command.description.map { $0.sanitizedCmuxConfigText }
                    ?? String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"),
                keywords: command.keywords ?? [],
                palette: true,
                shortcut: nil,
                icon: .symbol(command.workspace == nil ? "terminal" : "rectangle.stack.badge.plus"),
                tooltip: command.description,
                action: command.workspace == nil
                    ? .command(command.command ?? "")
                    : .workspaceCommand(command.name),
                confirm: command.confirm,
                terminalCommandTarget: command.workspace == nil ? .currentTerminal : nil,
                actionSourcePath: sourcePath,
                iconSourcePath: nil
            )
        }

        return registry.values.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func resolvedSurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        actions: [String: CmuxResolvedConfigAction],
        settingName: String
    ) -> ResolvedSurfaceTabBarButtons? {
        var resolvedButtons: [CmuxSurfaceTabBarButton] = []
        var terminalCommandSourcePaths: [String: String] = [:]
        resolvedButtons.reserveCapacity(buttons.count)

        for button in buttons {
            do {
                let resolved = try resolvedSurfaceTabBarButton(button, actions: actions)
                resolvedButtons.append(resolved.button)
                guard resolved.button.terminalCommand != nil else { continue }
                if let commandSourcePath = resolved.terminalCommandSourcePath {
                    terminalCommandSourcePaths[resolved.button.id] = commandSourcePath
                }
            } catch {
                NSLog("[CmuxConfig] %@ ignored: %@", settingName, String(describing: error))
                return nil
            }
        }

        return ResolvedSurfaceTabBarButtons(
            buttons: resolvedButtons,
            terminalCommandSourcePaths: terminalCommandSourcePaths
        )
    }

    private func resolvedSurfaceTabBarButton(
        _ button: CmuxSurfaceTabBarButton,
        actions: [String: CmuxResolvedConfigAction]
    ) throws -> ResolvedSurfaceTabBarButtonEntry {
        guard case .actionReference(let identifier) = button.action else {
            return ResolvedSurfaceTabBarButtonEntry(button: button, terminalCommandSourcePath: nil)
        }

        let resolvedIdentifier = canonicalActionID(identifier)
        if let entry = actions[resolvedIdentifier] {
            let resolvedButton = CmuxSurfaceTabBarButton(
                id: button.id,
                title: button.title ?? entry.title,
                icon: button.icon ?? entry.icon,
                tooltip: button.tooltip ?? entry.tooltip ?? entry.title,
                action: entry.action,
                confirm: button.confirm ?? entry.confirm,
                terminalCommandTarget: button.terminalCommandTarget ?? entry.terminalCommandTarget,
                actionSourcePath: entry.actionSourcePath,
                iconSourcePath: button.icon == nil ? entry.iconSourcePath : button.iconSourcePath
            )
            return ResolvedSurfaceTabBarButtonEntry(
                button: resolvedButton,
                terminalCommandSourcePath: resolvedButton.terminalCommand == nil ? nil : entry.actionSourcePath
            )
        }

        if let builtIn = CmuxSurfaceTabBarBuiltInAction(configID: identifier) {
            return ResolvedSurfaceTabBarButtonEntry(
                button: CmuxSurfaceTabBarButton(
                    id: button.id,
                    title: button.title,
                    icon: button.icon,
                    tooltip: button.tooltip,
                    action: .builtIn(builtIn),
                    confirm: button.confirm,
                    terminalCommandTarget: button.terminalCommandTarget
                ),
                terminalCommandSourcePath: nil
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    private func applySurfaceTabBarButtonsToCurrentManager() {
        tabManager?.applySurfaceTabBarButtons(
            surfaceTabBarButtons,
            sourcePath: surfaceTabBarButtonSourcePath,
            globalConfigPath: globalConfigPath,
            terminalCommandSourcePaths: surfaceTabBarCommandSourcePaths,
            workspaceCommands: surfaceTabBarWorkspaceCommands
        )
    }

    private func resolvedSurfaceTabBarWorkspaceCommands(
        _ buttons: [CmuxSurfaceTabBarButton],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> (buttons: [CmuxSurfaceTabBarButton], workspaceCommands: [String: CmuxResolvedCommand]) {
        var visibleButtons: [CmuxSurfaceTabBarButton] = []
        var workspaceCommands: [String: CmuxResolvedCommand] = [:]
        visibleButtons.reserveCapacity(buttons.count)

        for button in buttons {
            guard let commandName = button.workspaceCommandName else {
                visibleButtons.append(button)
                continue
            }

            guard let command = resolvedWorkspaceCommand(
                named: commandName,
                settingName: "surfaceTabBarButtons action",
                commands: commands,
                sourcePaths: sourcePaths
            ) else {
                NSLog(
                    "[CmuxConfig] surfaceTabBarButtons action '%@' hidden because workspace command '%@' is unavailable",
                    button.id,
                    commandName
                )
                continue
            }

            visibleButtons.append(button)
            workspaceCommands[button.id] = command
        }

        return (visibleButtons, workspaceCommands)
    }

    func resolvedNewWorkspaceCommand() -> CmuxResolvedCommand? {
        resolvedNewWorkspaceCommandCache
    }

    func resolvedNewWorkspaceAction() -> CmuxResolvedConfigAction? {
        resolvedNewWorkspaceActionCache
    }

    func resolvedAction(id: String) -> CmuxResolvedConfigAction? {
        actionLookup[canonicalActionID(id)]
    }

    func paletteCustomActions() -> [CmuxResolvedConfigAction] {
        let builtInIDs = Set(CmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.palette && !builtInIDs.contains(action.id)
        }
    }

    func shortcutActions() -> [CmuxResolvedConfigAction] {
        let builtInIDs = Set(CmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.shortcut != nil && (builtInIDs.contains(action.id) || action.actionSourcePath != nil)
        }.sorted { lhs, rhs in
            let lhsPriority = builtInIDs.contains(lhs.id) ? 0 : 1
            let rhsPriority = builtInIDs.contains(rhs.id) ? 0 : 1
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func resolvedConfiguredNewWorkspaceAction(
        actionID: String?,
        actionSourcePath: String?,
        commandName: String?,
        commandSourcePath: String?,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceActionResolution {
        if let actionID {
            let resolvedActionID = canonicalActionID(actionID)
            guard let action = actions[resolvedActionID] else {
                let issue = CmuxConfigIssue(
                    kind: .newWorkspaceActionNotFound,
                    settingName: "ui.newWorkspace.action",
                    commandName: actionID,
                    sourcePath: actionSourcePath
                )
                NSLog("[CmuxConfig] %@", issue.logMessage)
                return NewWorkspaceActionResolution(action: nil, command: nil, issue: issue)
            }
            if let actionCommandName = action.workspaceCommandName {
                let commandResolution = resolvedConfiguredNewWorkspaceCommand(
                    named: actionCommandName,
                    settingName: "ui.newWorkspace.action",
                    settingSourcePath: action.actionSourcePath ?? actionSourcePath,
                    commands: commands,
                    sourcePaths: sourcePaths
                )
                guard commandResolution.issue == nil else {
                    return NewWorkspaceActionResolution(
                        action: nil,
                        command: commandResolution.command,
                        issue: commandResolution.issue
                    )
                }
                return NewWorkspaceActionResolution(
                    action: action,
                    command: commandResolution.command,
                    issue: nil
                )
            }
            return NewWorkspaceActionResolution(action: action, command: nil, issue: nil)
        }

        guard let commandName else {
            return NewWorkspaceActionResolution(action: nil, command: nil, issue: nil)
        }
        let commandResolution = resolvedConfiguredNewWorkspaceCommand(
            named: commandName,
            settingName: "newWorkspaceCommand",
            settingSourcePath: commandSourcePath,
            commands: commands,
            sourcePaths: sourcePaths
        )
        guard let command = commandResolution.command else {
            return NewWorkspaceActionResolution(action: nil, command: nil, issue: commandResolution.issue)
        }
        return NewWorkspaceActionResolution(
            action: CmuxResolvedConfigAction(
                id: command.command.id,
                title: command.command.name,
                subtitle: command.command.description
                    ?? String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"),
                keywords: command.command.keywords ?? [],
                palette: false,
                shortcut: nil,
                icon: .symbol("rectangle.stack.badge.plus"),
                tooltip: command.command.description,
                action: .workspaceCommand(command.command.name),
                confirm: command.command.confirm,
                terminalCommandTarget: nil,
                actionSourcePath: command.sourcePath,
                iconSourcePath: nil
            ),
            command: command,
            issue: nil
        )
    }

    /// Public lookup: given an anchor workspace's cwd, return the best-matching
    /// resolved group config. Matching uses auto-glob detection (keys with `*`
    /// or `?` are treated as fnmatch globs, others as path prefixes). Longest
    /// matching key wins. Returns nil when nothing matches.
    func resolveWorkspaceGroupConfig(forCwd cwd: String?) -> CmuxResolvedWorkspaceGroupConfig? {
        guard let cwd, !cwd.isEmpty, !workspaceGroupConfigs.isEmpty else { return nil }
        let normalizedCwd = CmuxConfigCwdResolver().normalizeAbsolutePath(cwd)
        var best: (CmuxResolvedWorkspaceGroupConfig, Int)?
        for entry in workspaceGroupConfigs {
            guard Self.cwdEntryMatches(entry, cwd: normalizedCwd) else { continue }
            let score = entry.normalizedKey.count
            if best == nil || score > best!.1 {
                best = (entry, score)
            }
        }
        return best?.0
    }

    private static func cwdEntryMatches(
        _ entry: CmuxResolvedWorkspaceGroupConfig,
        cwd: String
    ) -> Bool {
        let key = entry.normalizedKey
        if entry.isGlob {
            return CmuxConfigCwdResolver.fnmatchStyle(pattern: key, candidate: cwd)
        }
        if cwd == key { return true }
        // Root prefix `/` is a documented catch-all; without this branch
        // any non-root cwd would be tested against "//" and fail. Other
        // keys append `/` so `/Users/lawrence` doesn't also match
        // `/Users/lawrence-fork`.
        if key == "/" {
            return cwd.hasPrefix("/")
        }
        return cwd.hasPrefix(key + "/")
    }

    private func resolveWorkspaceGroupConfigsFromLayers(
        localConfig: CmuxConfigFile?,
        globalConfig: CmuxConfigFile?,
        localPath: String?,
        globalPath: String,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        issues: inout [CmuxConfigIssue]
    ) -> [CmuxResolvedWorkspaceGroupConfig] {
        var resolved: [String: CmuxResolvedWorkspaceGroupConfig] = [:]
        if let globalEntries = globalConfig?.workspaceGroups?.byCwd {
            for (key, entry) in globalEntries {
                if let r = resolveWorkspaceGroupConfigEntry(
                    key: key, entry: entry, sourcePath: globalPath,
                    actions: actions, commands: commands,
                    sourcePaths: sourcePaths, issues: &issues
                ) {
                    resolved[r.normalizedKey] = r
                }
            }
        }
        if let localEntries = localConfig?.workspaceGroups?.byCwd {
            for (key, entry) in localEntries {
                if let r = resolveWorkspaceGroupConfigEntry(
                    key: key, entry: entry, sourcePath: localPath ?? globalPath,
                    actions: actions, commands: commands,
                    sourcePaths: sourcePaths, issues: &issues
                ) {
                    resolved[r.normalizedKey] = r // local overrides global
                }
            }
        }
        return Array(resolved.values).sorted { $0.normalizedKey.count > $1.normalizedKey.count }
    }

    private func resolveWorkspaceGroupConfigEntry(
        key: String,
        entry: CmuxConfigWorkspaceGroupEntry,
        sourcePath: String,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        issues: inout [CmuxConfigIssue]
    ) -> CmuxResolvedWorkspaceGroupConfig? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isGlob = trimmed.contains("*") || trimmed.contains("?")
        // Expand `~` in both glob and prefix keys so a key like
        // `~/projects/*` matches workspace cwds that are already normalized to
        // absolute paths (`/Users/<you>/projects/foo`). Prefix keys also go
        // through `standardizingPath` so trailing `/.` and similar are
        // canonicalized.
        let normalizedKey = isGlob
            ? CmuxConfigCwdResolver().expandTildePreservingGlob(trimmed)
            : CmuxConfigCwdResolver().normalizeAbsolutePath(trimmed)
        let menuResolution = resolvedConfigContextMenuItems(
            entry.contextMenu,
            actions: actions,
            commands: commands,
            sourcePaths: sourcePaths,
            settingName: "workspaceGroups.byCwd[\(key)].contextMenu",
            settingSourcePath: sourcePath
        )
        issues.append(contentsOf: menuResolution.issues)
        return CmuxResolvedWorkspaceGroupConfig(
            originalKey: trimmed,
            normalizedKey: normalizedKey,
            isGlob: isGlob,
            color: entry.color.map { $0.sanitizedCmuxConfigText },
            iconSymbol: entry.icon.map { $0.sanitizedCmuxConfigText },
            contextMenuItems: menuResolution.items,
            newWorkspacePlacement: WorkspaceGroupNewPlacement(rawString: entry.newWorkspacePlacement)
        )
    }

    private func resolvedConfigContextMenuItems(
        _ configuredItems: [CmuxConfigContextMenuItem]?,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        settingName: String,
        settingSourcePath: String?
    ) -> ResolvedContextMenuItems {
        guard let configuredItems, !configuredItems.isEmpty else {
            return ResolvedContextMenuItems(items: [], issues: [])
        }
        var resolvedItems: [CmuxResolvedConfigContextMenuItem] = []
        var issues: [CmuxConfigIssue] = []
        resolvedItems.reserveCapacity(configuredItems.count)

        for (index, configuredItem) in configuredItems.enumerated() {
            let itemSettingName = "\(settingName)[\(index)]"
            switch configuredItem {
            case .separator:
                guard !resolvedItems.isEmpty else { continue }
                if let last = resolvedItems.last, case .separator = last {
                    continue
                }
                resolvedItems.append(.separator(id: "\(settingName).separator.\(index)"))
            case .action(let item):
                let resolvedActionID = canonicalActionID(item.action)
                guard let action = actions[resolvedActionID] else {
                    let issue = CmuxConfigIssue(
                        kind: .newWorkspaceActionNotFound,
                        settingName: itemSettingName,
                        commandName: item.action,
                        sourcePath: settingSourcePath
                    )
                    NSLog("[CmuxConfig] %@", issue.logMessage)
                    issues.append(issue)
                    continue
                }
                if let actionCommandName = action.workspaceCommandName {
                    let commandResolution = resolvedConfiguredNewWorkspaceCommand(
                        named: actionCommandName,
                        settingName: itemSettingName,
                        settingSourcePath: action.actionSourcePath ?? settingSourcePath,
                        commands: commands,
                        sourcePaths: sourcePaths
                    )
                    if let issue = commandResolution.issue {
                        issues.append(issue)
                        continue
                    }
                    guard commandResolution.command != nil else {
                        continue
                    }
                }
                resolvedItems.append(
                    .action(
                        CmuxResolvedConfigMenuAction(
                            id: "\(settingName).\(index).\(action.id)",
                            title: (item.title ?? action.title).sanitizedCmuxConfigText(fallback: action.id),
                            icon: item.icon ?? action.icon,
                            iconSourcePath: item.icon == nil ? action.iconSourcePath : settingSourcePath,
                            tooltip: (item.tooltip ?? action.tooltip).map { $0.sanitizedCmuxConfigText },
                            action: action
                        )
                    )
                )
            }
        }

        if let last = resolvedItems.last, case .separator = last {
            resolvedItems.removeLast()
        }
        return ResolvedContextMenuItems(items: resolvedItems, issues: issues)
    }

    private func canonicalActionID(_ id: String) -> String {
        CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
    }

    private func resolvedConfiguredNewWorkspaceCommand(
        named commandName: String,
        settingName: String,
        settingSourcePath: String?,
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceCommandResolution {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandNotFound,
                settingName: settingName,
                commandName: commandName,
                sourcePath: settingSourcePath
            )
        }
        guard command.workspace != nil else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandRequiresWorkspace,
                settingName: settingName,
                commandName: commandName,
                sourcePath: sourcePaths[command.id] ?? settingSourcePath
            )
        }
        return NewWorkspaceCommandResolution(
            command: CmuxResolvedCommand(command: command, sourcePath: sourcePaths[command.id]),
            issue: nil
        )
    }

    private func newWorkspaceResolutionIssue(
        kind: CmuxConfigIssue.Kind,
        settingName: String,
        commandName: String?,
        sourcePath: String?
    ) -> NewWorkspaceCommandResolution {
        let issue = CmuxConfigIssue(
            kind: kind,
            settingName: settingName,
            commandName: commandName,
            sourcePath: sourcePath
        )
        NSLog("[CmuxConfig] %@", issue.logMessage)
        return NewWorkspaceCommandResolution(command: nil, issue: issue)
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String
    ) -> CmuxResolvedCommand? {
        resolvedWorkspaceCommand(
            named: commandName,
            settingName: settingName,
            commands: loadedCommands,
            sourcePaths: commandSourcePaths
        )
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String,
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> CmuxResolvedCommand? {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            NSLog("[CmuxConfig] %@ '%@' does not match any loaded command", settingName, commandName)
            return nil
        }
        guard command.workspace != nil else {
            NSLog("[CmuxConfig] %@ '%@' must reference a workspace command", settingName, commandName)
            return nil
        }
        return CmuxResolvedCommand(command: command, sourcePath: sourcePaths[command.id])
    }

    // MARK: - Parsing

    private func parseConfig(at path: String) -> ParsedConfigResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            parsedConfigCache.removeValue(forKey: path)
            return ParsedConfigResult(config: nil, issue: nil)
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date
        let paletteFingerprint = WorkspaceTabColorSettings.paletteCacheFingerprint()

        if let cached = parsedConfigCache[path],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate,
           cached.workspaceColorPaletteFingerprint == paletteFingerprint {
            return ParsedConfigResult(config: cached.config, issue: cached.issue)
        }

        guard let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            let issue = schemaErrorFormatter.schemaIssue(path: path, message: "cmux.json is empty")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            return ParsedConfigResult(config: nil, issue: issue)
        }
        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            let issue = schemaErrorFormatter.schemaIssue(path: path, message: "JSONC preprocessing failed: \(schemaErrorFormatter.schemaErrorMessage(error))")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            NSLog("[CmuxConfig] JSONC preprocessing error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(config: nil, issue: issue)
        }

        do {
            let decoder = JSONDecoder()
            // Inject the app's AppKit-coupled color resolver so the moved
            // `CmuxWorkspaceDefinition` value type (in CmuxWorkspaces) normalizes a
            // `workspace.color` string identically to the legacy in-line decode,
            // without the package reaching up into the app target.
            decoder.userInfo[.cmuxWorkspaceColorResolver]
                = { @Sendable (raw: String, defaults: UserDefaults) -> String? in
                    WorkspaceTabColorSettings.resolvedColorHex(raw, defaults: defaults)
                } as @Sendable (String, UserDefaults) -> String?
            let config = try decoder.decode(CmuxConfigFile.self, from: sanitized)
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: config,
                issue: nil
            )
            return ParsedConfigResult(config: config, issue: nil)
        } catch {
            let issue = schemaErrorFormatter.schemaIssue(path: path, message: schemaErrorFormatter.schemaErrorMessage(error))
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            NSLog("[CmuxConfig] parse error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(config: nil, issue: issue)
        }
    }

    // MARK: - File watching (local)

    private func startLocalFileWatcher() {
        guard let path = localConfigPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — watch the directory instead
            startLocalDirectoryWatcher()
            return
        }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopLocalFileWatcher()
                    self.loadAll()
                    self.scheduleLocalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
    }

    private func updateLocalHookFileWatchers(
        paths: [String],
        primaryLocalPath: String?
    ) {
        let desiredPaths = Set(paths.filter { path in
            path != primaryLocalPath && FileManager.default.fileExists(atPath: path)
        })
        for path in Array(hookWatchers.keys) where !desiredPaths.contains(path) {
            stopLocalHookFileWatcher(at: path)
        }
        for path in desiredPaths where hookWatchers[path] == nil {
            startLocalHookFileWatcher(at: path)
        }
    }

    private func startLocalHookFileWatcher(at path: String) {
        let watcher = FileWatcher(path: path)
        hookWatchers[path] = watcher
        let events = watcher.events
        hookWatchTasks[path] = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.loadAll()
            }
        }
    }

    private func stopLocalHookFileWatcher(at path: String) {
        hookWatchTasks.removeValue(forKey: path)?.cancel()
        hookWatchers.removeValue(forKey: path)
    }

    private func stopLocalHookFileWatchers() {
        hookWatchTasks.values.forEach { $0.cancel() }
        hookWatchTasks.removeAll()
        hookWatchers.removeAll()
    }

    private func startLocalDirectoryWatcher() {
        guard let path = localConfigPath else { return }
        let configDirectory = (path as NSString).deletingLastPathComponent
        let fs = FileManager.default
        let dirPath: String
        if fs.fileExists(atPath: configDirectory) {
            dirPath = configDirectory
        } else if let searchDirectory = localConfigSearchDirectory,
                  fs.fileExists(atPath: searchDirectory) {
            dirPath = searchDirectory
        } else {
            dirPath = (configDirectory as NSString).deletingLastPathComponent
        }
        let eventHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.handleLocalDirectoryWatchEvent()
            }
        }

        guard let primaryWatch = startLocalDirectoryWatchSource(at: dirPath, eventHandler: eventHandler) else {
            return
        }
        localFileWatchSource = primaryWatch.source
        localFileDescriptor = primaryWatch.fileDescriptor

        if let searchDirectory = localConfigSearchDirectory,
           fs.fileExists(atPath: configDirectory),
           searchDirectory != dirPath,
           let fallbackWatch = startLocalDirectoryWatchSource(at: searchDirectory, eventHandler: eventHandler) {
            localFallbackDirectoryWatchSource = fallbackWatch.source
            localFallbackDirectoryDescriptor = fallbackWatch.fileDescriptor
        }
    }

    private func startLocalDirectoryWatchSource(
        at dirPath: String,
        eventHandler: @escaping () -> Void
    ) -> (source: DispatchSourceFileSystemObject, fileDescriptor: Int32)? {
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler(handler: eventHandler)
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return (source, fd)
    }

    private func handleLocalDirectoryWatchEvent() {
        if let searchDirectory = localConfigSearchDirectory {
            let resolvedPath = resolvedLocalConfigPath(startingFrom: searchDirectory)
            if resolvedPath != localConfigPath {
                localConfigPath = resolvedPath
            }
        }
        guard let configPath = localConfigPath else { return }
        let configDirectory = (configPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: configPath) ||
            FileManager.default.fileExists(atPath: configDirectory) else { return }
        // File or its parent directory appeared — switch to file-level watching.
        stopLocalFileWatcher()
        loadAll()
        startLocalFileWatcher()
    }

    private func scheduleLocalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let path = self.localConfigPath else { return }
                if FileManager.default.fileExists(atPath: path) {
                    self.loadAll()
                    self.startLocalFileWatcher()
                } else {
                    self.startLocalDirectoryWatcher()
                }
            }
        }
    }

    private func stopLocalFileWatcher() {
        if let source = localFileWatchSource {
            source.cancel()
            localFileWatchSource = nil
        }
        stopLocalHookFileWatchers()
        if let source = localFallbackDirectoryWatchSource {
            source.cancel()
            localFallbackDirectoryWatchSource = nil
        }
        localFileDescriptor = -1
        localFallbackDirectoryDescriptor = -1
    }

    // MARK: - File watching (global)

    /// Watches the global config via ``CmuxFileWatch/FileWatcher``, which handles
    /// inode reattachment and nearest-existing-ancestor recovery internally; each
    /// change reloads. Ensures the config directory exists first (the previous
    /// directory-watcher created it).
    private func startGlobalWatching() {
        stopGlobalWatching()
        let dirPath = (globalConfigPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dirPath) {
            try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        let watcher = FileWatcher(path: globalConfigPath)
        globalWatcher = watcher
        let events = watcher.events
        globalWatchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.loadAll()
            }
        }
    }

    private func stopGlobalWatching() {
        globalWatchTask?.cancel()
        globalWatchTask = nil
        globalWatcher = nil
    }
}

extension CmuxConfigStore {
    /// Thin forwarder kept for source compatibility; the implementation lives on
    /// ``CmuxConfigCwdResolver`` in CmuxFoundation.
    static func resolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        CmuxConfigCwdResolver().resolveCwd(cwd, relativeTo: baseCwd)
    }
}
