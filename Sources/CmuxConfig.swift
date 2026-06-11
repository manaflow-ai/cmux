import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation
import Observation

@Observable
@MainActor
final class CmuxConfigStore {
    static let defaultNewWorkspaceContextMenu: [CmuxConfigContextMenuItem] = [
        .action(CmuxConfigContextMenuActionItem(action: CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID)),
        .action(CmuxConfigContextMenuActionItem(action: CmuxSurfaceTabBarBuiltInAction.cloudVM.configID)),
    ]

    var loadedCommands: [CmuxCommandDefinition] = []
    var loadedActions: [CmuxResolvedConfigAction] = []
    var newWorkspaceCommandName: String?
    var newWorkspaceActionID: String?
    var newWorkspaceContextMenuItems: [CmuxResolvedConfigContextMenuItem] = []
    /// Resolved per-cwd workspace group customization, keyed by the JSON cwd key.
    /// Use `resolveWorkspaceGroupConfig(forCwd:)` to find the best match for an
    /// anchor workspace's cwd. Empty when no `workspaceGroups.byCwd` block is
    /// configured.
    var workspaceGroupConfigs: [CmuxResolvedWorkspaceGroupConfig] = []
    var surfaceTabBarButtons: [CmuxSurfaceTabBarButton] = CmuxSurfaceTabBarButton.defaults
    var notificationHooks: [CmuxResolvedNotificationHook] = []
    var configurationIssues: [CmuxConfigIssue] = []
    var configRevision: UInt64 = 0

    // The properties below are internal bookkeeping that was never `@Published`
    // under the previous `ObservableObject` conformance, so views never
    // re-rendered on their mutation. `@ObservationIgnored` preserves those
    // exact invalidation semantics and keeps cache writes (which can happen
    // from helpers invoked during view-body evaluation, e.g. `parseConfig`)
    // from registering as tracked mutations.

    /// Which config file each command came from, keyed by command id.
    @ObservationIgnored var commandSourcePaths: [String: String] = [:]
    @ObservationIgnored var actionLookup: [String: CmuxResolvedConfigAction] = [:]
    @ObservationIgnored var surfaceTabBarButtonSourcePath: String?
    @ObservationIgnored var surfaceTabBarCommandSourcePaths: [String: String] = [:]
    @ObservationIgnored var newWorkspaceActionSourcePath: String?

    @ObservationIgnored var localConfigPath: String?
    @ObservationIgnored weak var tabManager: TabManager?
    let globalConfigPath: String
    let fileWatchingEnabled: Bool

    nonisolated private static func defaultGlobalConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
    }

    struct ActionEntry {
        let definition: CmuxConfigActionDefinition
        let sourcePath: String?
    }

    struct ResolvedSurfaceTabBarButtonEntry {
        let button: CmuxSurfaceTabBarButton
        let terminalCommandSourcePath: String?
    }

    struct ResolvedSurfaceTabBarButtons {
        let buttons: [CmuxSurfaceTabBarButton]
        let terminalCommandSourcePaths: [String: String]
    }

    struct ResolvedContextMenuItems {
        let items: [CmuxResolvedConfigContextMenuItem]
        let issues: [CmuxConfigIssue]
    }

    struct NewWorkspaceCommandResolution {
        let command: CmuxResolvedCommand?
        let issue: CmuxConfigIssue?
    }

    struct NewWorkspaceActionResolution {
        let action: CmuxResolvedConfigAction?
        let command: CmuxResolvedCommand?
        let issue: CmuxConfigIssue?
    }

    struct ParsedConfigCacheEntry {
        let fileSize: UInt64
        let modificationDate: Date?
        let workspaceColorPaletteFingerprint: String
        let config: CmuxConfigFile?
        let issue: CmuxConfigIssue?
    }

    struct ParsedConfigResult {
        let config: CmuxConfigFile?
        let issue: CmuxConfigIssue?
    }

    @ObservationIgnored var surfaceTabBarWorkspaceCommands: [String: CmuxResolvedCommand] = [:]
    @ObservationIgnored var resolvedNewWorkspaceCommandCache: CmuxResolvedCommand?
    @ObservationIgnored var resolvedNewWorkspaceActionCache: CmuxResolvedConfigAction?
    @ObservationIgnored var parsedConfigCache: [String: ParsedConfigCacheEntry] = [:]
    @ObservationIgnored private var lifetimeCancellables = Set<AnyCancellable>()
    @ObservationIgnored var trackingCancellables = Set<AnyCancellable>()
    // The local config still uses a bespoke DispatchSource watcher because it
    // performs search-directory *path re-resolution* (not just reload-on-change).
    // The global config and hook files use CmuxFileWatch.FileWatcher.
    @ObservationIgnored var localFileWatchSource: DispatchSourceFileSystemObject?
    @ObservationIgnored var localFileDescriptor: Int32 = -1
    @ObservationIgnored var localConfigSearchDirectory: String?
    @ObservationIgnored var hookWatchers: [String: FileWatcher] = [:]
    @ObservationIgnored var hookWatchTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var localFallbackDirectoryWatchSource: DispatchSourceFileSystemObject?
    @ObservationIgnored var localFallbackDirectoryDescriptor: Int32 = -1
    @ObservationIgnored var globalWatcher: FileWatcher?
    @ObservationIgnored var globalWatchTask: Task<Void, Never>?
    let watchQueue = DispatchQueue(label: "com.cmux.config-file-watch")

    static let maxReattachAttempts = 5
    static let reattachDelay: TimeInterval = 0.5

    private static func searchDirectoryForLocalConfigPath(_ path: String) -> String {
        let configDirectory = (path as NSString).deletingLastPathComponent
        if (configDirectory as NSString).lastPathComponent == ".cmux" {
            return (configDirectory as NSString).deletingLastPathComponent
        }
        return configDirectory
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    init(
        globalConfigPath: String = CmuxConfigStore.defaultGlobalConfigPath(),
        localConfigPath: String? = nil,
        startFileWatchers: Bool = false
    ) {
        self.globalConfigPath = globalConfigPath
        self.localConfigPath = localConfigPath
        self.fileWatchingEnabled = startFileWatchers
        self.localConfigSearchDirectory = localConfigPath.map(Self.searchDirectoryForLocalConfigPath(_:))
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

}

extension CmuxConfigStore {
    static func resolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "." else {
            return baseCwd
        }
        if cwd.hasPrefix("~/") || cwd == "~" {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if cwd == "~" { return home }
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseCwd as NSString).appendingPathComponent(cwd)
    }
}
