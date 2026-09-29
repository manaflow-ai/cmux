import AppKit
import CmuxCloud
import CmuxFileTree
import CmuxFoundation
import Combine
import Foundation

// MARK: - Store

/// Main-actor owner of one Files tree: root, provider, row nodes, expansion,
/// selection and git status.
///
/// Listing, sorting and diffing run in a ``FileTreeEngine`` off the main
/// actor. The store applies each ``FileTreeDirectoryUpdate`` to its node graph
/// and forwards the diff to ``FileExplorerTreeObserving`` observers, which
/// update `NSOutlineView` with batch inserts and removals instead of
/// `reloadData`. Only root-level status is `@Published`; per-row changes never
/// pass through SwiftUI.
@MainActor
final class FileExplorerStore: ObservableObject {
    @Published var rootPath: String = ""
    @Published internal(set) var isRootLoading: Bool = false
    /// Bumped when the root reloads or a filesystem change batch lands. Find
    /// uses it to refresh searches.
    @Published internal(set) var contentRevision = 0
    @Published private(set) var rootStatusMessage: String?
    private(set) var workspaceRootIdentity: UUID?

    var provider: FileExplorerProvider?

    /// Whether hidden files are shown. Toggling re-filters cached listings without I/O.
    var showHiddenFiles: Bool = true {
        didSet {
            guard oldValue != showHiddenFiles else { return }
            applyPresentationChange()
        }
    }

    /// Sibling order. Changing it re-sorts cached listings without I/O.
    var sortOrder: FileTreeSortOrder = .standard {
        didSet {
            guard oldValue != sortOrder else { return }
            applyPresentationChange()
        }
    }

    // MARK: Tree state

    /// Top-level rows, in display order.
    internal(set) var rootNodes: [FileExplorerNode] = []
    /// Every materialized row by path.
    internal(set) var nodesByPath: [String: FileExplorerNode] = [:]
    /// Directories the viewer expanded. Survives reloads and provider swaps.
    internal(set) var expandedPaths: Set<String> = []
    /// Stable keyboard/navigation anchor.
    internal(set) var selectedPath: String?
    /// Stable multi-selection; `selectedPath` is its anchor.
    internal(set) var selectedPaths: Set<String> = []
    /// Directories with a listing in flight.
    internal(set) var loadingPaths: Set<String> = []
    /// Git status by absolute path. Row colors refresh through observers, not SwiftUI.
    private(set) var gitStatusByPath: [String: GitFileStatus] = [:]

    var workspaceRootObservation: FileExplorerWorkspaceObservation?
    var remoteHomeResolutionTask: Task<Void, Never>?
    var remoteHomeResolutionKey: String?
    let cloudPreviewCache = CloudFilePreviewCache()
    private(set) var resourceContextID = UUID()

    // MARK: Internal machinery (see FileExplorerStore+Tree.swift)

    var treeSession: FileExplorerTreeSession?
    var treeSessionCounter: UInt64 = 0
    var observers: [WeakFileExplorerTreeObserver] = []
    var pendingLoadPaths: [String] = []
    var pendingSilentLoadPaths: Set<String> = []
    var loadFlushTask: Task<Void, Never>?
    var pendingRefreshPaths: Set<String> = []
    var refreshTask: Task<Void, Never>?
    var watchTask: Task<Void, Never>?
    var frozenUpdateDepth = 0
    var deferredUpdates: [(sessionID: UInt64, updates: [FileTreeDirectoryUpdate])] = []
    var pendingDescendIntoFirstChildPath: String?
    var pendingRenamePath: String?
    var pendingScrollAnchor: (path: String, offset: Double)?
    var recursiveExpansionBudget = 0
    var recursiveExpansionRoots: Set<String> = []
    let prefetchScheduler = MainActorDeferredActionScheduler()
    var viewStateSaveTask: Task<Void, Never>?
    let viewStateRepository: FileTreeViewStateRepository?

    private let gitStatusProvider: GitStatusProvider
    private var gitStatusGeneration: UInt64 = 0
    private var gitStatusTask: Task<Void, Never>?
    private var gitStatusNeedsRerun = false

    init(
        gitStatusProvider: GitStatusProvider = GitStatusProvider(),
        viewStateRepository: FileTreeViewStateRepository? = nil
    ) {
        self.gitStatusProvider = gitStatusProvider
        self.viewStateRepository = viewStateRepository
    }

    var displayRootPath: String {
        if rootPath.isEmpty, let cloudProvider = provider as? CloudVMFileExplorerProvider {
            return cloudProvider.displayTarget
        }
        if let sshProvider = provider as? SSHFileExplorerProvider {
            guard !rootPath.isEmpty else {
                return "ssh://\(sshProvider.displayTarget)"
            }
            return "ssh://\(sshProvider.displayTarget):\(rootPath)"
        }
        return FileExplorerRootResolver.displayPath(for: rootPath, homePath: provider?.homePath)
    }

    /// Whether mutations (new, rename, trash, drop) are available: local roots only.
    var supportsFileOperations: Bool {
        provider is LocalFileExplorerProvider && !rootPath.isEmpty
    }

    // MARK: - Public API

    func applyWorkspaceRoot(
        _ request: FileExplorerWorkspaceRoot,
        sshTransport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        switch request {
        case .none:
            workspaceRootObservation?.stop(); workspaceRootObservation = nil
            cancelRemoteHomeResolution(); setRootStatusMessage(nil); setWorkspaceRootIdentity(nil)
            if provider != nil { setProvider(nil, reloadIfAvailable: false) }
            setRootPath("")
        case .local(let workspaceId, let path):
            cancelRemoteHomeResolution(); setRootStatusMessage(nil); setWorkspaceRootIdentity(workspaceId)
            if !(provider is LocalFileExplorerProvider) {
                setRootPath("")
                setProvider(LocalFileExplorerProvider(), reloadIfAvailable: false)
            }
            setRootPath(path)
        case .remoteSSH(let workspaceId, let connection, let displayTarget, let rootPath, let isAvailable, let unavailableDetail):
            applyRemoteSSHWorkspaceRoot(
                workspaceId: workspaceId,
                connection: connection,
                displayTarget: displayTarget,
                rootPath: rootPath,
                isAvailable: isAvailable,
                unavailableDetail: unavailableDetail,
                sshTransport: sshTransport
            )
        case .remoteCloud(let workspaceId, let vmID, let displayTarget, let rootPath, let isAvailable, let unavailableDetail, let target):
            applyRemoteCloudWorkspaceRoot(
                workspaceId: workspaceId,
                vmID: vmID,
                displayTarget: displayTarget,
                rootPath: rootPath,
                isAvailable: isAvailable,
                unavailableDetail: unavailableDetail, target: target
            )
        }
    }

    func setWorkspaceRootIdentity(_ identity: UUID?) {
        guard workspaceRootIdentity != identity else { return }
        saveViewStateNow()
        workspaceRootIdentity = identity
        resetResourceContext()
        rootPath = ""
    }

    func setRootStatusMessage(_ message: String?) {
        guard rootStatusMessage != message else { return }
        rootStatusMessage = message
    }

    private func resetResourceContext(preservingNavigation: Bool = false) {
        resourceContextID = UUID()
        cancelRemoteHomeResolution()
        if !preservingNavigation {
            selectedPath = nil; selectedPaths = []; expandedPaths = []
            pendingScrollAnchor = nil
        }
        gitStatusByPath = [:]
        tearDownTree()
        contentRevision &+= 1
    }

    func setRootPath(_ path: String) {
        guard path != rootPath else { return }
        saveViewStateNow()
        if !Self.path(selectedPath ?? path, isContainedIn: path) || path.isEmpty {
            selectedPath = nil
            selectedPaths = []
            pendingDescendIntoFirstChildPath = nil
        }
        // Expanded folders outside the new root belong to the old one.
        expandedPaths = expandedPaths.filter { Self.path($0, isContainedIn: path) }
        resourceContextID = UUID()
        rootPath = path
        reload(restoringViewState: true)
        refreshGitStatus()
    }

    func setProvider(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        let providerChanged: Bool
        switch (provider, newProvider) {
        case let (current?, next?): providerChanged = current !== next
        case (nil, nil): providerChanged = false
        default: providerChanged = true
        }
        if providerChanged {
            saveViewStateNow()
            resetResourceContext(preservingNavigation: true)
        }
        provider = newProvider
        if reloadIfAvailable, newProvider?.isAvailable == true {
            reload()
        }
    }

    #if DEBUG
    func setProviderForTesting(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        setProvider(newProvider, reloadIfAvailable: reloadIfAvailable)
    }
    #endif

    /// Called when an SSH provider becomes available after being unavailable.
    /// Re-lists the root and every expanded folder in one batch.
    func hydrateExpandedNodes() {
        guard let provider, provider.isAvailable, !expandedPaths.isEmpty else { return }
        reload()
    }

    // MARK: - Git status

    /// Refreshes git colors; at most one `git status` runs at a time and a
    /// request during a run schedules exactly one rerun.
    func refreshGitStatus() {
        guard !rootPath.isEmpty, provider?.isAvailable == true,
              provider is LocalFileExplorerProvider || provider is SSHFileExplorerProvider else {
            gitStatusGeneration &+= 1
            gitStatusTask?.cancel()
            gitStatusTask = nil
            gitStatusNeedsRerun = false
            if !gitStatusByPath.isEmpty { applyGitStatus([:]) }
            return
        }
        guard gitStatusTask == nil else {
            gitStatusNeedsRerun = true
            return
        }
        gitStatusGeneration &+= 1
        let generation = gitStatusGeneration, path = rootPath
        let context = resourceContextID, source = gitStatusProvider
        let connection = (provider as? SSHFileExplorerProvider)?.connection
        gitStatusTask = Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                if let connection {
                    return source.fetchStatusSSH(directory: path, destination: connection.destination,
                        port: connection.port, identityFile: connection.identityFile, sshOptions: connection.sshOptions)
                }
                return source.fetchStatus(directory: path)
            }.value
            guard let self, self.gitStatusGeneration == generation else { return }
            self.gitStatusTask = nil
            if self.resourceContextID == context {
                self.applyGitStatus(status)
            }
            if self.gitStatusNeedsRerun {
                self.gitStatusNeedsRerun = false
                self.refreshGitStatus()
            }
        }
    }

    private func applyGitStatus(_ status: [String: GitFileStatus]) {
        guard status != gitStatusByPath else { return }
        let previous = gitStatusByPath
        gitStatusByPath = status
        var changed = Set<String>()
        for (path, value) in status where previous[path] != value { changed.insert(path) }
        for path in previous.keys where status[path] == nil { changed.insert(path) }
        let nodes = changed.compactMap { nodesByPath[$0] }
        if !nodes.isEmpty {
            notifyObservers { $0.fileExplorerTree(self, didRefreshRowsFor: nodes) }
        }
    }

    // MARK: - Remote previews

    func materializeRemoteFileForPreview(
        path: String,
        expectedWorkspaceRootIdentity: UUID? = nil
    ) async throws -> URL {
        // `DisableFileTransfer` (MDM): a preview copies the file off the remote
        // host onto this Mac, which is a cmux-mediated download.
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard expectedWorkspaceRootIdentity == nil || workspaceRootIdentity == expectedWorkspaceRootIdentity,
              let remoteProvider = provider as? SSHFileExplorerProvider else {
            throw FileExplorerError.providerUnavailable
        }
        let cacheURL = Self.remotePreviewCacheURL(
            displayTarget: remoteProvider.displayTarget,
            remotePath: path
        )
        try await remoteProvider.downloadFile(path: path, to: cacheURL)
        guard expectedWorkspaceRootIdentity == nil ||
              (workspaceRootIdentity == expectedWorkspaceRootIdentity && provider === remoteProvider) else {
            try? FileManager.default.removeItem(at: cacheURL)
            throw FileExplorerError.providerUnavailable
        }
        return cacheURL
    }

    private static func remotePreviewCacheURL(displayTarget: String, remotePath: String) -> URL {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-file-previews", isDirectory: true)
        let target = sanitizedCacheComponent(displayTarget)
        let remote = sanitizedCacheComponent(remotePath)
        let basename = URL(fileURLWithPath: remotePath).lastPathComponent
        let filename = basename.isEmpty ? remote : "\(remote)-\(basename)"
        return cacheRoot
            .appendingPathComponent(target, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private static func sanitizedCacheComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let candidate = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return candidate.isEmpty ? UUID().uuidString : String(candidate.prefix(160))
    }

    deinit {
        remoteHomeResolutionTask?.cancel()
        loadFlushTask?.cancel()
        refreshTask?.cancel()
        watchTask?.cancel()
        gitStatusTask?.cancel()
        viewStateSaveTask?.cancel()
    }
}

/// Weak box so observers never keep a dismantled outline alive.
struct WeakFileExplorerTreeObserver {
    weak var observer: (any FileExplorerTreeObserving)?
}
