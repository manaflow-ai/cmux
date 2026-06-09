import AppKit
import CmuxFileWatch
import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Models

struct FileExplorerEntry: Sendable {
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

struct SSHFileExplorerConnection: Equatable, Sendable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
}

protocol SSHFileExplorerTransport: AnyObject {
    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String
    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry]
    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws
}

enum FileExplorerWorkspaceRoot: Equatable {
    case none
    case local(path: String)
    case remoteSSH(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?
    )
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

// Captured by async SSH tasks; mutable availability/root state is guarded by stateLock.
final class SSHFileExplorerProvider: FileExplorerProvider, @unchecked Sendable {
    private struct State: Sendable {
        var homePath: String
        var isAvailable: Bool
    }

    let connection: SSHFileExplorerConnection
    let displayTarget: String
    private let transport: SSHFileExplorerTransport
    private let stateLock = NSLock()
    private var state: State

    var homePath: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.homePath
    }

    var isAvailable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.isAvailable
    }

    var destination: String { connection.destination }
    var port: Int? { connection.port }
    var identityFile: String? { connection.identityFile }
    var sshOptions: [String] { connection.sshOptions }

    init(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        displayTarget: String? = nil,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = SSHFileExplorerConnection(
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions
        )
        self.displayTarget = displayTarget ?? {
            guard let port else { return destination }
            return "\(destination):\(port)"
        }()
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    init(
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = connection
        self.displayTarget = displayTarget
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    func updateAvailability(_ available: Bool, homePath: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        state.isAvailable = available
        if let homePath {
            state.homePath = homePath
        }
    }

    func resolveHomePath() async throws -> String {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        let home = try await transport.resolveHomePath(connection: connection)
        guard !home.isEmpty else {
            throw FileExplorerError.sshCommandFailed("remote HOME was empty")
        }
        return home
    }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        return try await transport.listDirectory(path: path, connection: connection, showHidden: showHidden)
    }

    func downloadFile(path: String, to localURL: URL) async throws {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        try await transport.downloadFile(path: path, connection: connection, to: localURL)
    }
}

final class ProcessSSHFileExplorerTransport: SSHFileExplorerTransport {
    static let shared = ProcessSSHFileExplorerTransport()

    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        let output = try await Self.runSSHCommand(
            connection: connection,
            command: #"printf '%s\n' "$HOME""#
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        try await Self.runSSHListCommand(path: path, connection: connection, showHidden: showHidden)
    }

    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws {
        let escapedPath = Self.shellSingleQuote(path)
        let outputURL = localURL
        let commandProcess = SSHDownloadCommandProcess(
            connection: connection,
            command: "cat -- \(escapedPath)",
            outputURL: outputURL
        )
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }
        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
    }

    private struct SSHCommandResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    // Keeps the child process reachable from the cancellation handler while
    // the blocking wait runs off Swift's cooperative executor.
    private final class SSHCommandProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let lock = NSLock()
        private let terminationGate = ProcessTerminationGate()
        private var cancelled = false

        init(connection: SSHFileExplorerConnection, command: String) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: command)
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run() throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            do {
                try process.run()
            } catch {
                terminationGate.markFinished()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            lock.unlock()
            if terminationGate.markLaunched() || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    terminationGate.markFinished()
                    throw CancellationError()
                }
                process.terminate()
            }

            let data = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: outPipe.fileHandleForReading)
            let stderrData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: errPipe.fileHandleForReading)
            process.waitUntilExit()
            terminationGate.markFinished()
            lock.lock()
            let cancelledAfterExit = cancelled
            lock.unlock()
            if cancelledAfterExit {
                throw CancellationError()
            }

            return SSHCommandResult(
                stdout: String(data: data, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            lock.unlock()

            guard terminationGate.requestTermination() else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private final class SSHDownloadCommandProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let outputURL: URL
        private let lock = NSLock()
        private let terminationGate = ProcessTerminationGate()
        private var cancelled = false

        init(connection: SSHFileExplorerConnection, command: String, outputURL: URL) {
            self.outputURL = outputURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: command)
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run() throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }

            do {
                try process.run()
            } catch {
                terminationGate.markFinished()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            lock.unlock()
            if terminationGate.markLaunched() || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    terminationGate.markFinished()
                    throw CancellationError()
                }
                process.terminate()
            }

            try ProcessPipeReader.copyDataToEndOfFile(
                from: outPipe.fileHandleForReading,
                to: outputHandle
            )
            let stderrData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: errPipe.fileHandleForReading)
            process.waitUntilExit()
            terminationGate.markFinished()
            lock.lock()
            let cancelledAfterExit = cancelled
            lock.unlock()
            if cancelledAfterExit {
                throw CancellationError()
            }

            return SSHCommandResult(
                stdout: "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            lock.unlock()

            guard terminationGate.requestTermination() else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private static func runSSHCommand(connection: SSHFileExplorerConnection, command: String) async throws -> String {
        let commandProcess = SSHCommandProcess(connection: connection, command: command)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }

        guard result.terminationStatus == 0 else {
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
        return result.stdout
    }

    private static func sshArguments(connection: SSHFileExplorerConnection, command: String) -> [String] {
        var args: [String] = []
        if let port = connection.port {
            args += ["-p", String(port)]
        }
        if let identityFile = connection.identityFile {
            args += ["-i", identityFile]
        }
        for option in connection.sshOptions {
            args += ["-o", option]
        }
        // Batch mode, no TTY, connection timeout
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        args += [connection.destination, command]
        return args
    }

    private static func runSSHListCommand(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        // Escape single quotes in path for shell safety
        let escapedPath = shellSingleQuote(path)
        let lsFlags = showHidden ? "-1paFA" : "-1paF"
        let output = try await runSSHCommand(
            connection: connection,
            command: "ls \(lsFlags) \(escapedPath) 2>/dev/null"
        )

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

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum FileExplorerError: LocalizedError {
    case providerUnavailable
    case sshCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
        case .sshCommandFailed:
            return String(localized: "fileExplorer.error.sshFailed", defaultValue: "SSH command failed")
        }
    }
}

// MARK: - Mutation Errors

/// Failures surfaced when creating, renaming, duplicating, or trashing items in the
/// local file explorer. SSH-backed roots do not support mutation and return
/// ``providerUnsupported``.
enum FileExplorerMutationError: LocalizedError {
    /// The active provider is not the local filesystem (e.g. an SSH workspace).
    case providerUnsupported
    /// The supplied name was empty or contained a path separator.
    case invalidName
    /// An item with the requested name already exists in the destination directory.
    case alreadyExists(name: String)
    /// A `FileManager` operation threw; the associated value is the system message.
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .providerUnsupported:
            return String(localized: "fileExplorer.mutation.error.unsupported", defaultValue: "This action isn't available for remote folders.")
        case .invalidName:
            return String(localized: "fileExplorer.mutation.error.invalidName", defaultValue: "Names can't be empty or contain a slash.")
        case .alreadyExists(let name):
            let format = String(localized: "fileExplorer.mutation.error.alreadyExists", defaultValue: "An item named \"%@\" already exists.")
            return String(format: format, name)
        case .underlying(let message):
            return message
        }
    }
}

// MARK: - Selection Restoration

enum FileExplorerSelectionRestoration {
    static func scrollRow(anchorRow: Int?, exactRows: IndexSet) -> Int? {
        if let anchorRow, exactRows.contains(anchorRow) {
            return anchorRow
        }
        return exactRows.first
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
    @Published private(set) var rootStatusMessage: String?

    var provider: FileExplorerProvider?

    /// Whether hidden files are shown. Set from FileExplorerState externally.
    var showHiddenFiles: Bool = false

    /// Watches the root directory for filesystem changes (local only).
    private var directoryWatcher: FileWatcher?
    private var directoryWatchTask: Task<Void, Never>?
    private var directoryWatchPath: String?

    /// Single source of truth for "an inline name edit is in progress." While true, both the
    /// filesystem watcher and the view's reload pass suspend reloads so the active field editor
    /// is never torn down. Clearing it replays a single coalesced reload if any watch event was
    /// missed in the meantime. The view reads this instead of keeping its own parallel flag, so
    /// the reload-gating lifecycle has one owner rather than two independent mechanisms.
    var isInteractivelyEditing = false {
        didSet {
            guard oldValue, !isInteractivelyEditing, pendingWatcherReload else { return }
            pendingWatcherReload = false
            reload()
            refreshGitStatus()
        }
    }
    private var pendingWatcherReload = false

    /// Paths that are logically expanded (persisted across provider changes)
    private(set) var expandedPaths: Set<String> = []

    /// Stable navigation selection. The outline view mirrors this path after reloads.
    private(set) var selectedPath: String?

    /// Stable multi-selection. `selectedPath` remains the keyboard/navigation anchor.
    private(set) var selectedPaths: Set<String> = []

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

    private var remoteHomeResolutionTask: Task<Void, Never>?
    private var remoteHomeResolutionKey: String?

    var displayRootPath: String {
        if let sshProvider = provider as? SSHFileExplorerProvider {
            guard !rootPath.isEmpty else {
                return "ssh://\(sshProvider.displayTarget)"
            }
            return "ssh://\(sshProvider.displayTarget):\(rootPath)"
        }
        return FileExplorerRootResolver.displayPath(for: rootPath, homePath: provider?.homePath)
    }

    // MARK: - Public API

    func applyWorkspaceRoot(
        _ request: FileExplorerWorkspaceRoot,
        sshTransport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        switch request {
        case .none:
            cancelRemoteHomeResolution()
            setRootStatusMessage(nil)
            if provider != nil {
                setProvider(nil, reloadIfAvailable: false)
            }
            setRootPath("")

        case .local(let path):
            cancelRemoteHomeResolution()
            setRootStatusMessage(nil)
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
        }
    }

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
            selectedPaths = []
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

    func materializeRemoteFileForPreview(path: String) async throws -> URL {
        guard let sshProvider = provider as? SSHFileExplorerProvider else {
            throw FileExplorerError.providerUnavailable
        }
        let cacheURL = Self.remotePreviewCacheURL(
            displayTarget: sshProvider.displayTarget,
            remotePath: path
        )
        try await sshProvider.downloadFile(path: path, to: cacheURL)
        return cacheURL
    }

    private func updateDirectoryWatcher() {
        if provider is LocalFileExplorerProvider, !rootPath.isEmpty {
            guard directoryWatchPath != rootPath || directoryWatcher == nil else { return }
            stopDirectoryWatcher()
            // Preserve the previous 0.3s coalescing as a leading-edge throttle.
            let watcher = FileWatcher(path: rootPath, throttle: .milliseconds(300))
            directoryWatcher = watcher
            directoryWatchPath = rootPath
            let events = watcher.events
            directoryWatchTask = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    if self.isInteractivelyEditing {
                        self.pendingWatcherReload = true
                        continue
                    }
                    self.reload()
                    self.refreshGitStatus()
                }
            }
        } else {
            stopDirectoryWatcher()
        }
    }

    /// Cancels the directory-watch consumer and drops the watcher; the watcher's
    /// deinit cancels its `DispatchSource`s synchronously.
    private func stopDirectoryWatcher() {
        directoryWatchTask?.cancel()
        directoryWatchTask = nil
        directoryWatcher = nil
        directoryWatchPath = nil
    }

    private func setProvider(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        #if DEBUG
        NSLog("[FileExplorer] setProvider: \(type(of: newProvider).self) available=\(newProvider?.isAvailable ?? false)")
        #endif
        provider = newProvider
        // Re-expand previously expanded nodes if provider becomes available
        if reloadIfAvailable, newProvider?.isAvailable == true {
            reload()
        }
    }

    #if DEBUG
    func setProviderForTesting(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        setProvider(newProvider, reloadIfAvailable: reloadIfAvailable)
    }
    #endif

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
        let paths = path.map { Set([$0]) } ?? []
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func select(nodes: [FileExplorerNode], anchor: FileExplorerNode?) {
        let paths = Set(nodes.map(\.path))
        let path = anchor?.path ?? nodes.first?.path
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func requestDescendIntoFirstChild(of node: FileExplorerNode) {
        guard node.isDirectory else { return }
        selectedPath = node.path
        selectedPaths = [node.path]
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

    // MARK: - Mutations (local only)

    /// Whether the current provider supports filesystem mutations. Only the local
    /// provider can create, rename, duplicate, or trash items; SSH roots are read-only.
    var canMutate: Bool { provider is LocalFileExplorerProvider }

    /// The directory a toolbar-initiated "New File"/"New Folder" should target: the
    /// selected directory, the selected file's parent, or the root when nothing is selected.
    /// Returns `nil` when mutation is unsupported or no root is open.
    func targetDirectoryForNewItem() -> String? {
        guard canMutate, !rootPath.isEmpty else { return nil }
        guard let selectedPath else { return rootPath }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selectedPath, isDirectory: &isDirectory) else {
            return rootPath
        }
        return isDirectory.boolValue ? selectedPath : (selectedPath as NSString).deletingLastPathComponent
    }

    /// Returns a name that does not collide with an existing entry in `directory`, appending
    /// " 2", " 3", … to `base` as needed (e.g. `untitled`, `untitled 2`).
    func uniqueName(base: String, fileExtension ext: String, in directory: String) -> String {
        let fm = FileManager.default
        func compose(_ index: Int) -> String {
            let stem = index == 0 ? base : "\(base) \(index + 1)"
            return ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        var index = 0
        while fm.fileExists(atPath: (directory as NSString).appendingPathComponent(compose(index))) {
            index += 1
        }
        return compose(index)
    }

    /// Marks `path` as logically expanded so a newly created child becomes visible after reload.
    func ensureExpanded(path: String) {
        guard canMutate else { return }
        expandedPaths.insert(path)
    }

    /// Overrides the navigation selection by path. Survives the next reload because
    /// the outline view mirrors `selectedPath`/`selectedPaths` during restoration.
    func setSelection(path: String?) {
        selectedPath = path
        selectedPaths = path.map { [$0] } ?? []
    }

    /// Creates an empty file named `name` inside `directory`. Does not reload; the caller
    /// drives the reload so it can coordinate inline renaming of the new item.
    @discardableResult
    func createFile(named name: String, in directory: String) -> Result<String, FileExplorerMutationError> {
        guard canMutate else { return .failure(.providerUnsupported) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return .failure(.invalidName) }
        let path = (directory as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return .failure(.alreadyExists(name: trimmed)) }
        guard fm.createFile(atPath: path, contents: nil) else {
            return .failure(.underlying(String(localized: "fileExplorer.mutation.error.createFileFailed", defaultValue: "Couldn't create the file.")))
        }
        return .success(path)
    }

    /// Creates a directory named `name` inside `directory`. Does not reload (see ``createFile(named:in:)``).
    @discardableResult
    func createDirectory(named name: String, in directory: String) -> Result<String, FileExplorerMutationError> {
        guard canMutate else { return .failure(.providerUnsupported) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return .failure(.invalidName) }
        let path = (directory as NSString).appendingPathComponent(trimmed)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return .failure(.alreadyExists(name: trimmed)) }
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            return .failure(operationFailure(error))
        }
        return .success(path)
    }

    /// Renames the item at `path` to `newName` within the same directory, returning the new path.
    /// Re-points expansion and selection state when a directory is renamed.
    @discardableResult
    func rename(path: String, to newName: String) -> Result<String, FileExplorerMutationError> {
        guard canMutate else { return .failure(.providerUnsupported) }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return .failure(.invalidName) }
        let directory = (path as NSString).deletingLastPathComponent
        let destination = (directory as NSString).appendingPathComponent(trimmed)
        if destination == path { return .success(path) }
        let fm = FileManager.default
        // A case-only rename (e.g. Readme.md -> README.md) resolves to the same file on a
        // case-insensitive volume, so fileExists(destination) is true even though it's valid.
        let oldName = (path as NSString).lastPathComponent
        let isCaseOnlyRename = trimmed != oldName && trimmed.lowercased() == oldName.lowercased()
        guard isCaseOnlyRename || !fm.fileExists(atPath: destination) else {
            return .failure(.alreadyExists(name: trimmed))
        }
        if isCaseOnlyRename {
            // Case-only rename on a case-insensitive volume needs a two-step move through a
            // unique temp name. If the second move fails, roll the item back to its original
            // name so it's never stranded under the hidden temp path, and surface a clean
            // message rather than one that exposes the internal temp name.
            let tempName = uniqueName(base: ".cmux-rename", fileExtension: "", in: directory)
            let tempPath = (directory as NSString).appendingPathComponent(tempName)
            do {
                try fm.moveItem(atPath: path, toPath: tempPath)
            } catch {
                return .failure(operationFailure(error))
            }
            do {
                try fm.moveItem(atPath: tempPath, toPath: destination)
            } catch {
                try? fm.moveItem(atPath: tempPath, toPath: path)
                return .failure(.underlying(String(localized: "fileExplorer.mutation.error.renameFailed", defaultValue: "Couldn't rename the item.")))
            }
        } else {
            do {
                try fm.moveItem(atPath: path, toPath: destination)
            } catch {
                return .failure(operationFailure(error))
            }
        }
        repathState(from: path, to: destination)
        return .success(destination)
    }

    /// Copies the item at `path` next to itself with a " copy" suffix, returning the new path.
    @discardableResult
    func duplicate(path: String) -> Result<String, FileExplorerMutationError> {
        guard canMutate else { return .failure(.providerUnsupported) }
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let copyBase = String(format: String(localized: "fileExplorer.mutation.copySuffix", defaultValue: "%@ copy"), stem)
        let newName = uniqueName(base: copyBase, fileExtension: ext, in: directory)
        let destination = (directory as NSString).appendingPathComponent(newName)
        do {
            try fm.copyItem(atPath: path, toPath: destination)
        } catch {
            return .failure(operationFailure(error))
        }
        return .success(destination)
    }

    /// Moves the given items to the Trash (recoverable from Finder) and clears any
    /// expansion/selection state that referenced them.
    @discardableResult
    func moveToTrash(paths: [String]) -> Result<Void, FileExplorerMutationError> {
        guard canMutate else { return .failure(.providerUnsupported) }
        let fm = FileManager.default
        // Drop any path nested under another selected path: trashing the ancestor already
        // removes the descendant, whose path would then no longer exist and fail the move.
        let roots = paths.sorted().reduce(into: [String]()) { acc, path in
            if let ancestor = acc.last, path == ancestor || path.hasPrefix(ancestor + "/") { return }
            acc.append(path)
        }
        var trashed: [String] = []
        for path in roots {
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                trashed.append(path)
            } catch {
                // Items before this one were already trashed — clear their state before
                // surfacing the failure so nothing dangles pointing at removed paths.
                clearReferences(to: trashed)
                return .failure(operationFailure(error))
            }
        }
        // Clear state for every originally-selected path, including the nested ones.
        clearReferences(to: paths)
        return .success(())
    }

    /// A user-safe failure for a thrown `FileManager` error. The raw error — which can carry
    /// NSCocoa codes, errno values, or absolute paths — is logged in debug builds but never
    /// surfaced to the user; the returned message is a generic, localized string instead.
    private func operationFailure(_ error: Error) -> FileExplorerMutationError {
        #if DEBUG
        NSLog("[FileExplorer] mutation failed: \(error)")
        #endif
        return .underlying(String(localized: "fileExplorer.mutation.error.generic", defaultValue: "Couldn't complete the operation."))
    }

    /// Removes any expansion/selection state that points at `clearedPaths` or their descendants.
    ///
    /// Runs in O(N + M·d): the cleared paths go into a `Set` once (M), then each candidate is
    /// tested by walking up its own ancestors (bounded directory depth `d`) and probing the
    /// set — instead of scanning every cleared path for every candidate (the former O(N·M)).
    private func clearReferences(to clearedPaths: [String]) {
        guard !clearedPaths.isEmpty else { return }
        let cleared = Set(clearedPaths)
        let isClearedOrUnder: (String) -> Bool = { candidate in
            var current = candidate
            while true {
                if cleared.contains(current) { return true }
                let parent = (current as NSString).deletingLastPathComponent
                if parent == current || parent.isEmpty { return false }
                current = parent
            }
        }
        expandedPaths = expandedPaths.filter { !isClearedOrUnder($0) }
        selectedPaths = selectedPaths.filter { !isClearedOrUnder($0) }
        if let selectedPath, isClearedOrUnder(selectedPath) { self.selectedPath = nil }
    }

    /// Permanently removes a just-created, still-empty item when the user cancels its
    /// inline name editing. Unlike ``moveToTrash(paths:)`` this does not use the Trash,
    /// because the item never existed from the user's perspective.
    @discardableResult
    func discardJustCreated(path: String) -> Result<Void, FileExplorerMutationError> {
        guard canMutate else { return .failure(.providerUnsupported) }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            return .failure(operationFailure(error))
        }
        repathState(from: path, to: nil)
        return .success(())
    }

    /// Clears all logical expansion so the tree collapses to its root items.
    func collapseAll() {
        expandedPaths.removeAll()
        pendingDescendIntoFirstChildPath = nil
    }

    /// Re-points `expandedPaths` and selection when an item moves from `old` to `new`
    /// (a directory rename also moves its descendants). Passing `new == nil` drops the state.
    private func repathState(from old: String, to new: String?) {
        func remap(_ p: String) -> String? {
            guard let new else {
                return (p == old || p.hasPrefix(old + "/")) ? nil : p
            }
            if p == old { return new }
            if p.hasPrefix(old + "/") { return new + String(p.dropFirst(old.count)) }
            return p
        }
        expandedPaths = Set(expandedPaths.compactMap(remap))
        selectedPaths = Set(selectedPaths.compactMap(remap))
        selectedPath = selectedPath.flatMap(remap)
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
            try Task.checkCancellation()
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
                    let path = children.first?.path ?? parentNode.path
                    selectedPath = path
                    selectedPaths = [path]
                    pendingDescendIntoFirstChildPath = nil
                }
            } else {
                rootNodes = children
                isRootLoading = false
                setRootStatusMessage(nil)
                if selectedPath == nil {
                    selectedPath = children.first?.path
                    selectedPaths = selectedPath.map { Set([$0]) } ?? []
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
                    setRootStatusMessage(error.localizedDescription)
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

    private func applyRemoteSSHWorkspaceRoot(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        rootPath requestedRootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?,
        sshTransport: SSHFileExplorerTransport
    ) {
        let existingProvider = provider as? SSHFileExplorerProvider
        let sshProvider: SSHFileExplorerProvider
        if let existingProvider,
           existingProvider.connection == connection,
           existingProvider.displayTarget == displayTarget {
            sshProvider = existingProvider
            sshProvider.updateAvailability(isAvailable, homePath: nil)
        } else {
            cancelRemoteHomeResolution()
            setRootPath("")
            sshProvider = SSHFileExplorerProvider(
                connection: connection,
                displayTarget: displayTarget,
                homePath: "",
                isAvailable: isAvailable,
                transport: sshTransport
            )
            setProvider(sshProvider, reloadIfAvailable: false)
        }

        guard isAvailable else {
            cancelRemoteHomeResolution()
            setRootPath("")
            let detail = unavailableDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                setRootStatusMessage(
                    String(
                        localized: "fileExplorer.status.sshUnavailableWithDetail",
                        defaultValue: "SSH files unavailable: \(detail)"
                    )
                )
            } else {
                setRootStatusMessage(
                    String(localized: "fileExplorer.status.sshUnavailable", defaultValue: "SSH files unavailable")
                )
            }
            return
        }

        let requestedRootPath = Self.normalizedRootPath(requestedRootPath)
        if let requestedRootPath {
            cancelRemoteHomeResolution()
            setRootStatusMessage(nil)
            setRootPath(requestedRootPath)
            return
        }

        let currentHomePath = sshProvider.homePath
        if !currentHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setRootStatusMessage(nil)
            setRootPath(currentHomePath)
            return
        }

        resolveRemoteHome(
            workspaceId: workspaceId,
            provider: sshProvider,
            connection: connection
        )
    }

    private func resolveRemoteHome(
        workspaceId: UUID,
        provider sshProvider: SSHFileExplorerProvider,
        connection: SSHFileExplorerConnection
    ) {
        let resolutionKey = [
            workspaceId.uuidString,
            connection.destination,
            connection.port.map(String.init) ?? "",
            connection.identityFile ?? "",
            connection.sshOptions.joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}")

        guard remoteHomeResolutionKey != resolutionKey else { return }
        remoteHomeResolutionTask?.cancel()
        remoteHomeResolutionKey = resolutionKey
        setRootPath("")
        setRootStatusMessage(String(localized: "fileExplorer.status.sshResolvingHome", defaultValue: "Resolving remote home..."))

        remoteHomeResolutionTask = Task { [weak self, weak sshProvider] in
            guard let sshProvider else { return }
            do {
                let homePath = try await sshProvider.resolveHomePath()
                await MainActor.run { [weak self, weak sshProvider] in
                    guard let self,
                          let sshProvider,
                          self.remoteHomeResolutionKey == resolutionKey,
                          self.provider === sshProvider else { return }
                    self.remoteHomeResolutionKey = nil
                    self.remoteHomeResolutionTask = nil
                    sshProvider.updateAvailability(true, homePath: homePath)
                    self.setRootStatusMessage(nil)
                    self.setRootPath(homePath)
                }
            } catch {
                await MainActor.run { [weak self, weak sshProvider] in
                    guard let self,
                          let sshProvider,
                          self.remoteHomeResolutionKey == resolutionKey,
                          self.provider === sshProvider else { return }
                    self.remoteHomeResolutionKey = nil
                    self.remoteHomeResolutionTask = nil
                    self.setRootPath("")
                    self.setRootStatusMessage(
                        String(
                            localized: "fileExplorer.status.sshHomeFailed",
                            defaultValue: "Unable to resolve SSH home: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    private func cancelRemoteHomeResolution() {
        remoteHomeResolutionTask?.cancel()
        remoteHomeResolutionTask = nil
        remoteHomeResolutionKey = nil
    }

    private func setRootStatusMessage(_ message: String?) {
        guard rootStatusMessage != message else { return }
        rootStatusMessage = message
    }

    private static func path(_ candidate: String, isContainedIn root: String) -> Bool {
        guard !root.isEmpty else { return false }
        if root == "/" {
            return candidate.hasPrefix("/")
        }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func normalizedRootPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
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
        cancelRemoteHomeResolution()
        directoryWatchTask?.cancel()
    }
}

// MARK: - Git Status

enum GitFileStatus {
    case modified, added, deleted, renamed, untracked, ignored

    /// Single-letter badge shown on the trailing edge of a file row
    /// (`M`/`A`/`D`/`R`/`U`), matching Cursor's status column. Ignored files
    /// carry no badge.
    var statusLetter: String? {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .ignored: return nil
        }
    }

    /// Whether the file name should be rendered dimmed (reduced opacity),
    /// matching Cursor's treatment of git-ignored and untracked files.
    var dimsName: Bool {
        self == .ignored || self == .untracked
    }
}

/// Runs `git status --porcelain` and parses results into a path-to-status map.
enum GitStatusProvider {

    static func fetchStatus(directory: String) -> [String: GitFileStatus] {
        guard let repoRoot = gitRepoRoot(for: directory) else { return [:] }
        return parseGitStatus(
            output: runGit(in: repoRoot, arguments: ["status", "--porcelain", "--ignored"]),
            repoRoot: repoRoot,
            explorerRoot: directory
        )
    }

    static func fetchStatusSSH(
        directory: String, destination: String, port: Int?,
        identityFile: String?, sshOptions: [String]
    ) -> [String: GitFileStatus] {
        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "cd '\(escapedDir)' 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null && echo '---GIT_STATUS---' && git status --porcelain --ignored 2>/dev/null"
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
        if index == "!" && workTree == "!" { return .ignored }
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
        let dirStatus: GitFileStatus
        switch status {
        case .untracked: dirStatus = .untracked
        case .ignored: dirStatus = .ignored
        default: dirStatus = .modified
        }
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
            let data = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: pipe.fileHandleForReading)
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
            let data = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: pipe.fileHandleForReading)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
