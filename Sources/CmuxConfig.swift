import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation

@MainActor
final class CmuxConfigStore: ObservableObject {
    static let defaultNewWorkspaceContextMenu: [CmuxConfigContextMenuItem] = [
        .action(CmuxConfigContextMenuActionItem(action: CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID)),
        .action(CmuxConfigContextMenuActionItem(action: CmuxSurfaceTabBarBuiltInAction.cloudVM.configID)),
    ]

    @Published var loadedCommands: [CmuxCommandDefinition] = []
    @Published var loadedActions: [CmuxResolvedConfigAction] = []
    @Published var newWorkspaceCommandName: String?
    @Published var newWorkspaceActionID: String?
    @Published var newWorkspaceContextMenuItems: [CmuxResolvedConfigContextMenuItem] = []
    /// Resolved per-cwd workspace group customization, keyed by the JSON cwd key.
    /// Use `resolveWorkspaceGroupConfig(forCwd:)` to find the best match for an
    /// anchor workspace's cwd. Empty when no `workspaceGroups.byCwd` block is
    /// configured.
    @Published var workspaceGroupConfigs: [CmuxResolvedWorkspaceGroupConfig] = []
    @Published var surfaceTabBarButtons: [CmuxSurfaceTabBarButton] = CmuxSurfaceTabBarButton.defaults
    @Published var notificationHooks: [CmuxResolvedNotificationHook] = []
    @Published var configurationIssues: [CmuxConfigIssue] = []
    @Published var configRevision: UInt64 = 0

    /// Which config file each command came from, keyed by command id.
    var commandSourcePaths: [String: String] = [:]
    var actionLookup: [String: CmuxResolvedConfigAction] = [:]
    var surfaceTabBarButtonSourcePath: String?
    var surfaceTabBarCommandSourcePaths: [String: String] = [:]
    var newWorkspaceActionSourcePath: String?

    var localConfigPath: String?
    weak var tabManager: TabManager?
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

    var surfaceTabBarWorkspaceCommands: [String: CmuxResolvedCommand] = [:]
    var resolvedNewWorkspaceCommandCache: CmuxResolvedCommand?
    var resolvedNewWorkspaceActionCache: CmuxResolvedConfigAction?
    var parsedConfigCache: [String: ParsedConfigCacheEntry] = [:]
    private var lifetimeCancellables = Set<AnyCancellable>()
    var trackingCancellables = Set<AnyCancellable>()
    // The local config still uses a bespoke DispatchSource watcher because it
    // performs search-directory *path re-resolution* (not just reload-on-change).
    // The global config and hook files use CmuxFileWatch.FileWatcher.
    var localFileWatchSource: DispatchSourceFileSystemObject?
    var localFileDescriptor: Int32 = -1
    var localConfigSearchDirectory: String?
    var hookWatchers: [String: FileWatcher] = [:]
    var hookWatchTasks: [String: Task<Void, Never>] = [:]
    var localFallbackDirectoryWatchSource: DispatchSourceFileSystemObject?
    var localFallbackDirectoryDescriptor: Int32 = -1
    var globalWatcher: FileWatcher?
    var globalWatchTask: Task<Void, Never>?
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
