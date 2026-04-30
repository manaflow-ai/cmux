import AppKit
import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Explorer Visual Style

enum FileExplorerStyle: Int, CaseIterable {
    case liquidGlass = 0
    case highDensity = 1
    case terminalStealth = 2
    case proStudio = 3
    case finder = 4

    var label: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .highDensity: return "High-Density IDE"
        case .terminalStealth: return "Terminal Stealth"
        case .proStudio: return "Pro Studio"
        case .finder: return "Finder"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .liquidGlass: return 28
        case .highDensity: return 20
        case .terminalStealth: return 24
        case .proStudio: return 32
        case .finder: return 26
        }
    }

    var indentation: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 12
        case .terminalStealth: return 14
        case .proStudio: return 20
        case .finder: return 18
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 14
        case .terminalStealth: return 12
        case .proStudio: return 18
        case .finder: return 18
        }
    }

    var iconWeight: NSFont.Weight {
        switch self {
        case .liquidGlass: return .regular
        case .highDensity: return .regular
        case .terminalStealth: return .light
        case .proStudio: return .regular
        case .finder: return .medium
        }
    }

    var nameFont: NSFont {
        switch self {
        case .liquidGlass: return .systemFont(ofSize: 13, weight: .medium)
        case .highDensity: return .systemFont(ofSize: 11, weight: .regular)
        case .terminalStealth: return .monospacedSystemFont(ofSize: 12, weight: .regular)
        case .proStudio: return .systemFont(ofSize: 14, weight: .semibold)
        case .finder: return .systemFont(ofSize: 13, weight: .regular)
        }
    }

    var iconToTextSpacing: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 4
        case .terminalStealth: return 6
        case .proStudio: return 12
        case .finder: return 6
        }
    }

    var selectionInset: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 4
        case .finder: return 4
        }
    }

    var selectionRadius: CGFloat {
        switch self {
        case .liquidGlass: return 6
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 8
        case .finder: return 5
        }
    }

    var selectionColor: NSColor {
        switch self {
        case .liquidGlass: return .controlAccentColor.withAlphaComponent(0.15)
        case .highDensity: return .selectedContentBackgroundColor
        case .terminalStealth: return .controlAccentColor
        case .proStudio: return .controlAccentColor
        case .finder: return .controlAccentColor.withAlphaComponent(0.15)
        }
    }

    var hoverColor: NSColor {
        switch self {
        case .liquidGlass: return .labelColor.withAlphaComponent(0.05)
        case .highDensity: return .white.withAlphaComponent(0.05)
        case .terminalStealth: return .white.withAlphaComponent(0.03)
        case .proStudio: return .white.withAlphaComponent(0.1)
        case .finder: return .labelColor.withAlphaComponent(0.04)
        }
    }

    var usesBorderSelection: Bool {
        self == .terminalStealth
    }

    var fileIconTint: NSColor {
        switch self {
        case .liquidGlass: return .secondaryLabelColor
        case .highDensity: return .secondaryLabelColor
        case .terminalStealth: return .tertiaryLabelColor
        case .proStudio: return .secondaryLabelColor
        case .finder: return NSColor(white: 0.55, alpha: 1.0)
        }
    }

    var folderIconTint: NSColor {
        switch self {
        case .liquidGlass: return .systemBlue
        case .highDensity: return .secondaryLabelColor
        case .terminalStealth: return .tertiaryLabelColor
        case .proStudio: return .systemBlue
        case .finder: return .systemBlue
        }
    }

    func gitColor(for status: GitFileStatus) -> NSColor {
        switch self {
        case .liquidGlass:
            switch status {
            case .modified: return .systemOrange
            case .added: return .systemTeal
            case .deleted: return .systemRed
            case .renamed: return .systemPurple
            case .untracked: return .quaternaryLabelColor
            }
        case .highDensity:
            switch status {
            case .modified: return .systemYellow
            case .added: return .systemGreen
            case .deleted: return .systemRed
            case .renamed: return .systemBlue
            case .untracked: return .tertiaryLabelColor
            }
        case .terminalStealth:
            switch status {
            case .modified: return NSColor(red: 0.8, green: 0.7, blue: 0.4, alpha: 1.0)
            case .added: return NSColor(red: 0.5, green: 0.8, blue: 0.5, alpha: 1.0)
            case .deleted: return NSColor(red: 0.8, green: 0.4, blue: 0.4, alpha: 1.0)
            case .renamed: return NSColor(red: 0.5, green: 0.7, blue: 0.9, alpha: 1.0)
            case .untracked: return NSColor(white: 0.5, alpha: 1.0)
            }
        case .proStudio:
            switch status {
            case .modified: return .systemYellow
            case .added: return .systemGreen
            case .deleted: return .systemPink
            case .renamed: return .systemCyan
            case .untracked: return .systemGray
            }
        case .finder:
            switch status {
            case .modified: return .systemOrange
            case .added: return .systemGreen
            case .deleted: return .systemRed
            case .renamed: return .systemBlue
            case .untracked: return .tertiaryLabelColor
            }
        }
    }

    static var current: FileExplorerStyle {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "fileExplorer.style") == nil {
            return .highDensity
        }
        return FileExplorerStyle(rawValue: defaults.integer(forKey: "fileExplorer.style")) ?? .highDensity
    }
}

// MARK: - Models

struct FileExplorerEntry {
    let name: String
    let path: String
    let isDirectory: Bool
}

final class FileExplorerNode: Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileExplorerNode]?
    var isLoading: Bool = false
    var error: String?

    init(name: String, path: String, isDirectory: Bool) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    var isExpandable: Bool { isDirectory }

    var sortedChildren: [FileExplorerNode]? {
        children?.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

// MARK: - Root Resolver

enum FileExplorerRootResolver {
    static func displayPath(for fullPath: String, homePath: String?) -> String {
        guard let home = homePath, !home.isEmpty else { return fullPath }
        let normalizedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let normalizedPath = fullPath.hasSuffix("/") ? String(fullPath.dropLast()) : fullPath
        if normalizedPath == normalizedHome {
            return "~"
        }
        let homePrefix = normalizedHome + "/"
        if normalizedPath.hasPrefix(homePrefix) {
            return "~/" + normalizedPath.dropFirst(homePrefix.count)
        }
        return fullPath
    }
}

// MARK: - Provider Protocol

protocol FileExplorerProvider: AnyObject {
    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry]
    var homePath: String { get }
    var isAvailable: Bool { get }
}

// MARK: - Local Provider

final class LocalFileExplorerProvider: FileExplorerProvider {
    var homePath: String { NSHomeDirectory() }
    var isAvailable: Bool { true }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: path)
        return contents.compactMap { name in
            guard showHidden || !name.hasPrefix(".") else { return nil }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            return FileExplorerEntry(name: name, path: fullPath, isDirectory: isDir.boolValue)
        }
    }
}

// MARK: - SSH Provider

final class SSHFileExplorerProvider: FileExplorerProvider {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    private(set) var homePath: String
    private(set) var isAvailable: Bool

    init(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        homePath: String,
        isAvailable: Bool
    ) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.homePath = homePath
        self.isAvailable = isAvailable
    }

    func updateAvailability(_ available: Bool, homePath: String?) {
        self.isAvailable = available
        if let homePath {
            self.homePath = homePath
        }
    }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        // Capture immutable config values for Sendable closure
        let dest = destination
        let p = port
        let identity = identityFile
        let opts = sshOptions
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try SSHFileExplorerProvider.runSSHListCommand(
                        path: path, destination: dest, port: p,
                        identityFile: identity, sshOptions: opts,
                        showHidden: showHidden
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSSHListCommand(
        path: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String],
        showHidden: Bool
    ) throws -> [FileExplorerEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args: [String] = []
        if let port {
            args += ["-p", String(port)]
        }
        if let identityFile {
            args += ["-i", identityFile]
        }
        for option in sshOptions {
            args += ["-o", option]
        }
        // Batch mode, no TTY, connection timeout
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        // Escape single quotes in path for shell safety
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let lsFlags = showHidden ? "-1paFA" : "-1paF"
        args += [destination, "ls \(lsFlags) '\(escapedPath)' 2>/dev/null"]

        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        // Read pipe data before waitUntilExit to avoid deadlock when pipe buffer fills
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            throw FileExplorerError.sshCommandFailed(stderrStr)
        }
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let entry = String(line)
            // Skip . and .. entries
            guard entry != "./" && entry != "../" else { return nil }
            let isDir = entry.hasSuffix("/")
            let name = isDir ? String(entry.dropLast()) : entry
            guard showHidden || !name.hasPrefix(".") else { return nil }
            // Strip type indicators from -F flag (*, @, =, |) for files
            let cleanName: String
            if !isDir, let last = name.last, "*@=|".contains(last) {
                cleanName = String(name.dropLast())
            } else {
                cleanName = name
            }
            let fullPath = normalizedPath + cleanName
            return FileExplorerEntry(name: cleanName, path: fullPath, isDirectory: isDir)
        }
    }
}

enum FileExplorerError: LocalizedError {
    case providerUnavailable
    case sshCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
        case .sshCommandFailed(let detail):
            return String(localized: "fileExplorer.error.sshFailed", defaultValue: "SSH command failed: \(detail)")
        }
    }
}

// MARK: - State (visibility toggle)

final class FileExplorerState: ObservableObject {
    private static let modeKey = "rightSidebar.mode"
    private static let feedDockMigrationKey = "rightSidebar.feedDockMigrationApplied"

    @Published var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: "fileExplorer.isVisible") }
    }
    @Published var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: "fileExplorer.width") }
    }

    /// Proportion of sidebar height allocated to the tab list (0.0-1.0).
    /// The file explorer gets the remaining space below.
    @Published var dividerPosition: CGFloat {
        didSet { UserDefaults.standard.set(Double(dividerPosition), forKey: "fileExplorer.dividerPosition") }
    }

    /// Whether hidden files (dotfiles) are shown in the tree.
    @Published var showHiddenFiles: Bool {
        didSet { UserDefaults.standard.set(showHiddenFiles, forKey: "fileExplorer.showHidden") }
    }

    /// Active mode for the right sidebar (file tree or session index).
    @Published var mode: RightSidebarMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.isVisible = defaults.bool(forKey: "fileExplorer.isVisible")
        let storedWidth = defaults.double(forKey: "fileExplorer.width")
        self.width = storedWidth > 0 ? CGFloat(storedWidth) : 220
        let storedPosition = defaults.double(forKey: "fileExplorer.dividerPosition")
        self.dividerPosition = storedPosition > 0 ? CGFloat(storedPosition) : 0.6
        let storedShowHidden = defaults.object(forKey: "fileExplorer.showHidden")
        self.showHiddenFiles = storedShowHidden == nil ? true : defaults.bool(forKey: "fileExplorer.showHidden")
        let storedMode = defaults.string(forKey: Self.modeKey) ?? RightSidebarMode.files.rawValue
        if storedMode == RightSidebarMode.feed.rawValue,
           defaults.bool(forKey: Self.feedDockMigrationKey) == false {
            self.mode = .dock
            defaults.set(RightSidebarMode.dock.rawValue, forKey: Self.modeKey)
            defaults.set(true, forKey: Self.feedDockMigrationKey)
        } else {
            self.mode = RightSidebarMode(rawValue: storedMode) ?? .files
        }
    }

    func toggle() {
        setVisible(!isVisible)
    }

    func setVisible(_ nextValue: Bool) {
        guard isVisible != nextValue else { return }

        // Suppress both SwiftUI transactions and AppKit/Core Animation implicit layout changes.
        NSAnimationContext.beginGrouping()
        CATransaction.begin()
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.setDisableActions(true)

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isVisible = nextValue
        }
    }
}

// MARK: - Store

/// All access must happen on the main thread. Properties are not marked @MainActor
/// because NSOutlineView data source/delegate methods are called on the main thread
/// but are not annotated @MainActor.
final class FileExplorerStore: ObservableObject {
    @Published var rootPath: String = ""
    @Published var rootNodes: [FileExplorerNode] = []
    @Published private(set) var isRootLoading: Bool = false
    @Published private(set) var gitStatusByPath: [String: GitFileStatus] = [:]
    @Published private(set) var contentRevision = 0

    var provider: FileExplorerProvider?

    /// Whether hidden files are shown. Set from FileExplorerState externally.
    var showHiddenFiles: Bool = false

    /// Watches the root directory for filesystem changes (local only).
    private var directoryWatcher: FileExplorerDirectoryWatcher?

    /// Paths that are logically expanded (persisted across provider changes)
    private(set) var expandedPaths: Set<String> = []

    /// Stable navigation selection. The outline view mirrors this path after reloads.
    private(set) var selectedPath: String?

    /// Folder path whose first child should be selected once its async load completes.
    private var pendingDescendIntoFirstChildPath: String?

    /// Paths currently being loaded
    private(set) var loadingPaths: Set<String> = []

    /// In-flight load tasks keyed by path
    private var loadTasks: [String: Task<Void, Never>] = [:]

    /// Cache of path -> node for quick lookup
    private var nodesByPath: [String: FileExplorerNode] = [:]

    /// Prefetch debounce: path -> work item
    private var prefetchWorkItems: [String: DispatchWorkItem] = [:]

    var displayRootPath: String {
        FileExplorerRootResolver.displayPath(for: rootPath, homePath: provider?.homePath)
    }

    // MARK: - Public API

    func setRootPath(_ path: String) {
        guard path != rootPath else {
            #if DEBUG
            NSLog("[FileExplorer] setRootPath skipped (same path): \(path)")
            #endif
            return
        }
        #if DEBUG
        NSLog("[FileExplorer] setRootPath: \(rootPath) -> \(path)")
        #endif
        if let selectedPath, !Self.path(selectedPath, isContainedIn: path) {
            self.selectedPath = nil
            pendingDescendIntoFirstChildPath = nil
        }
        rootPath = path
        reload()
        refreshGitStatus()
        updateDirectoryWatcher()
    }

    func refreshGitStatus() {
        guard !rootPath.isEmpty else {
            gitStatusByPath = [:]
            return
        }
        let path = rootPath
        if let sshProvider = provider as? SSHFileExplorerProvider {
            let dest = sshProvider.destination
            let port = sshProvider.port
            let identity = sshProvider.identityFile
            let opts = sshProvider.sshOptions
            DispatchQueue.global(qos: .utility).async {
                let status = GitStatusProvider.fetchStatusSSH(
                    directory: path, destination: dest, port: port,
                    identityFile: identity, sshOptions: opts
                )
                DispatchQueue.main.async { [weak self] in
                    self?.gitStatusByPath = status
                }
            }
        } else {
            DispatchQueue.global(qos: .utility).async {
                let status = GitStatusProvider.fetchStatus(directory: path)
                DispatchQueue.main.async { [weak self] in
                    self?.gitStatusByPath = status
                }
            }
        }
    }

    private func updateDirectoryWatcher() {
        if provider is LocalFileExplorerProvider, !rootPath.isEmpty {
            if directoryWatcher == nil {
                directoryWatcher = FileExplorerDirectoryWatcher { [weak self] in
                    self?.reload()
                    self?.refreshGitStatus()
                }
            }
            directoryWatcher?.watch(path: rootPath)
        } else {
            directoryWatcher?.stop()
        }
    }

    func setProvider(_ newProvider: FileExplorerProvider?) {
        #if DEBUG
        NSLog("[FileExplorer] setProvider: \(type(of: newProvider).self) available=\(newProvider?.isAvailable ?? false)")
        #endif
        provider = newProvider
        // Re-expand previously expanded nodes if provider becomes available
        if newProvider?.isAvailable == true {
            reload()
        }
    }

    func reload() {
        #if DEBUG
        NSLog("[FileExplorer] reload() path=\(rootPath) provider=\(type(of: provider).self)")
        #endif
        contentRevision &+= 1
        cancelAllLoads()
        rootNodes = []
        nodesByPath = [:]
        guard !rootPath.isEmpty, provider != nil else { return }
        isRootLoading = true
        let path = rootPath
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadChildren(for: nil, at: path)
        }
        loadTasks[rootPath] = task
    }

    func expand(node: FileExplorerNode) {
        guard node.isDirectory else { return }
        expandedPaths.insert(node.path)
        if node.children == nil, loadTasks[node.path] == nil, !loadingPaths.contains(node.path) {
            node.isLoading = true
            node.error = nil
            objectWillChange.send()
            let nodePath = node.path
            let task = Task { [weak self] in
                guard let self else { return }
                await self.loadChildren(for: node, at: nodePath)
            }
            loadTasks[node.path] = task
        }
    }

    func collapse(node: FileExplorerNode) {
        expandedPaths.remove(node.path)
        if pendingDescendIntoFirstChildPath == node.path {
            pendingDescendIntoFirstChildPath = nil
        }
        objectWillChange.send()
    }

    func isExpanded(_ node: FileExplorerNode) -> Bool {
        expandedPaths.contains(node.path)
    }

    func select(node: FileExplorerNode?) {
        let path = node?.path
        guard selectedPath != path else { return }
        selectedPath = path
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func requestDescendIntoFirstChild(of node: FileExplorerNode) {
        guard node.isDirectory else { return }
        selectedPath = node.path
        pendingDescendIntoFirstChildPath = node.path
        expand(node: node)
    }

    func prefetchChildren(for node: FileExplorerNode) {
        guard node.isDirectory, node.children == nil, !loadingPaths.contains(node.path) else { return }
        // Debounce: only prefetch if hover persists for 200ms
        let path = node.path
        prefetchWorkItems[path]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, node.children == nil, !self.loadingPaths.contains(path) else { return }
                // Silent prefetch: don't show loading indicator
                await self.loadChildren(for: node, at: path, silent: true)
            }
        }
        prefetchWorkItems[path] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func cancelPrefetch(for node: FileExplorerNode) {
        prefetchWorkItems[node.path]?.cancel()
        prefetchWorkItems.removeValue(forKey: node.path)
    }

    /// Called when SSH provider becomes available after being unavailable.
    /// Re-hydrates expanded nodes that were waiting.
    func hydrateExpandedNodes() {
        guard let provider, provider.isAvailable, !expandedPaths.isEmpty else { return }
        #if DEBUG
        NSLog("[FileExplorer] hydrateExpandedNodes: \(expandedPaths.count) paths to hydrate")
        #endif
        reload()
    }

    // MARK: - Private

    @MainActor
    private func loadChildren(for parentNode: FileExplorerNode?, at path: String, silent: Bool = false) async {
        guard let provider else { return }

        if !silent {
            loadingPaths.insert(path)
            parentNode?.error = nil
            objectWillChange.send()
        }

        do {
            let entries = try await provider.listDirectory(path: path, showHidden: showHiddenFiles)
            let children = entries.map { entry in
                let node = FileExplorerNode(name: entry.name, path: entry.path, isDirectory: entry.isDirectory)
                nodesByPath[entry.path] = node
                return node
            }.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            if let parentNode {
                parentNode.children = children
                parentNode.isLoading = false
                parentNode.error = nil
                if pendingDescendIntoFirstChildPath == parentNode.path {
                    selectedPath = children.first?.path ?? parentNode.path
                    pendingDescendIntoFirstChildPath = nil
                }
            } else {
                rootNodes = children
                isRootLoading = false
                if selectedPath == nil {
                    selectedPath = children.first?.path
                }
            }
            loadingPaths.remove(path)
            loadTasks.removeValue(forKey: path)
            objectWillChange.send()

            // Auto-expand children that were previously expanded
            for child in children where child.isDirectory && expandedPaths.contains(child.path) {
                child.isLoading = true
                objectWillChange.send()
                let childPath = child.path
                let childTask = Task { [weak self] in
                    guard let self else { return }
                    await self.loadChildren(for: child, at: childPath)
                }
                loadTasks[child.path] = childTask
            }
        } catch {
            if !Task.isCancelled {
                if let parentNode {
                    parentNode.isLoading = false
                    parentNode.error = error.localizedDescription
                } else {
                    isRootLoading = false
                }
                loadingPaths.remove(path)
                loadTasks.removeValue(forKey: path)
                objectWillChange.send()
            }
        }
    }

    private func cancelAllLoads() {
        for (_, task) in loadTasks {
            task.cancel()
        }
        loadTasks.removeAll()
        loadingPaths.removeAll()
        pendingDescendIntoFirstChildPath = nil
        for (_, item) in prefetchWorkItems {
            item.cancel()
        }
        prefetchWorkItems.removeAll()
        isRootLoading = false
    }

    private static func path(_ candidate: String, isContainedIn root: String) -> Bool {
        guard !root.isEmpty else { return false }
        if root == "/" {
            return candidate.hasPrefix("/")
        }
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

// MARK: - Directory Watcher

/// Watches a local directory for filesystem changes and calls back on the main thread.
/// Debounces events to avoid rapid-fire reloads during bulk operations (e.g., git checkout).
final class FileExplorerDirectoryWatcher {
    private var fileDescriptor: Int32 = -1
    private var watchSource: DispatchSourceFileSystemObject?
    private let watchQueue = DispatchQueue(label: "com.cmux.fileExplorerWatcher", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(path: String) {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename, .delete],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        watchSource = source
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        watchSource?.cancel()
        watchSource = nil
        fileDescriptor = -1
    }

    private func scheduleReload() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.onChange()
            }
        }
        debounceWorkItem = work
        watchQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    deinit {
        stop()
    }
}

// MARK: - Git Status

enum GitFileStatus {
    case modified, added, deleted, renamed, untracked
}

/// Runs `git status --porcelain` and parses results into a path-to-status map.
enum GitStatusProvider {

    static func fetchStatus(directory: String) -> [String: GitFileStatus] {
        guard let repoRoot = gitRepoRoot(for: directory) else { return [:] }
        return parseGitStatus(
            output: runGit(in: repoRoot, arguments: ["status", "--porcelain"]),
            repoRoot: repoRoot,
            explorerRoot: directory
        )
    }

    static func fetchStatusSSH(
        directory: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) -> [String: GitFileStatus] {
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd '\(escapedDir)' 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null && echo '---GIT_STATUS---' && git status --porcelain 2>/dev/null"
        guard let output = runSSH(
            command: cmd, destination: destination,
            port: port, identityFile: identityFile, sshOptions: sshOptions
        ) else { return [:] }

        let parts = output.components(separatedBy: "---GIT_STATUS---\n")
        guard parts.count == 2 else { return [:] }
        let repoRoot = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return parseGitStatus(output: parts[1], repoRoot: repoRoot, explorerRoot: directory)
    }

    private static func parseGitStatus(
        output: String?, repoRoot: String, explorerRoot: String
    ) -> [String: GitFileStatus] {
        guard let output, !output.isEmpty else { return [:] }
        var statusMap: [String: GitFileStatus] = [:]

        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let indexStatus = line[line.startIndex]
            let workTreeStatus = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")

            if path.contains(" -> ") {
                path = String(path.split(separator: " -> ").last ?? Substring(path))
            }

            guard let status = parseStatusChars(index: indexStatus, workTree: workTreeStatus) else { continue }

            let absolutePath = repoRoot.hasSuffix("/") ? repoRoot + path : repoRoot + "/" + path
            guard absolutePath.hasPrefix(explorerRoot) else { continue }

            statusMap[absolutePath] = status
            markParentDirectories(absolutePath: absolutePath, explorerRoot: explorerRoot, status: status, in: &statusMap)
        }
        return statusMap
    }

    private static func parseStatusChars(index: Character, workTree: Character) -> GitFileStatus? {
        if index == "?" && workTree == "?" { return .untracked }
        if index == "A" || workTree == "A" { return .added }
        if index == "D" || workTree == "D" { return .deleted }
        if index == "R" || workTree == "R" { return .renamed }
        if index == "M" || workTree == "M" { return .modified }
        return nil
    }

    private static func markParentDirectories(
        absolutePath: String, explorerRoot: String,
        status: GitFileStatus, in map: inout [String: GitFileStatus]
    ) {
        let dirStatus: GitFileStatus = (status == .untracked) ? .untracked : .modified
        var current = (absolutePath as NSString).deletingLastPathComponent
        while current.hasPrefix(explorerRoot) && current != explorerRoot {
            if map[current] == nil {
                map[current] = dirStatus
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func gitRepoRoot(for directory: String) -> String? {
        runGit(in: directory, arguments: ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runGit(in directory: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func runSSH(
        command: String, destination: String,
        port: Int?, identityFile: String?, sshOptions: [String]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args: [String] = []
        if let port { args += ["-p", String(port)] }
        if let identityFile { args += ["-i", identityFile] }
        for option in sshOptions { args += ["-o", option] }
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        args += [destination, command]
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
