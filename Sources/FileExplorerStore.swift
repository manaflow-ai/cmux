import CmuxCloud
import CmuxFoundation
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
        let baseHeight: CGFloat
        switch self {
        case .liquidGlass: baseHeight = 28
        case .highDensity: baseHeight = 20
        case .terminalStealth: baseHeight = 24
        case .proStudio: baseHeight = 32
        case .finder: baseHeight = 26
        }
        return GlobalFontMagnification.scaledSize(baseHeight)
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
        case .liquidGlass: return GlobalFontMagnification.systemFont(ofSize: 13, weight: .medium)
        case .highDensity: return GlobalFontMagnification.systemFont(ofSize: 11, weight: .regular)
        case .terminalStealth: return GlobalFontMagnification.monospacedSystemFont(ofSize: 12, weight: .regular)
        case .proStudio: return GlobalFontMagnification.systemFont(ofSize: 14, weight: .semibold)
        case .finder: return GlobalFontMagnification.systemFont(ofSize: 13, weight: .regular)
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
        palette.fileIconTint
    }

    var folderIconTint: NSColor {
        palette.folderIconTint
    }

    func gitColor(for status: GitFileStatus) -> NSColor {
        palette.gitColor(for: status)
    }

    private var palette: FileExplorerPalette {
        switch self {
        case .liquidGlass: .liquidGlass
        case .highDensity: .highDensity
        case .terminalStealth: .terminalStealth
        case .proStudio: .proStudio
        case .finder: .finder
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

struct FileExplorerEntry: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let creationDate: Date?
    let modificationDate: Date?

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

final class FileExplorerNode: Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let creationDate: Date?
    let modificationDate: Date?
    var children: [FileExplorerNode]?
    var isLoading: Bool = false
    var error: String?
    var resourceContextID: UUID?

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    var isExpandable: Bool { isDirectory }
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
    case local(workspaceId: UUID, path: String)
    case remoteSSH(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?
    )
    case remoteCloud(
        workspaceId: UUID,
        vmID: String,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?,
        target: CloudFileExplorerTarget?
    )
}

// MARK: - Local Provider

final class LocalFileExplorerProvider: FileExplorerProvider {
    var homePath: String { NSHomeDirectory() }
    var isAvailable: Bool { true }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
            options: []
        )
        return contents.compactMap { url in
            let name = url.lastPathComponent
            guard showHidden || !name.hasPrefix(".") else { return nil }
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
            )
            return FileExplorerEntry(
                name: name,
                path: url.path,
                isDirectory: values?.isDirectory ?? false,
                creationDate: values?.creationDate,
                modificationDate: values?.contentModificationDate
            )
        }
    }
}

// MARK: - SSH Provider

// Captured by async SSH tasks; mutable availability/root state is guarded by stateLock.
final class SSHFileExplorerProvider: RemoteFileExplorerProvider, @unchecked Sendable {
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
    nonisolated var remoteIdentity: String {
        "ssh:\(connection.destination)|\(connection.port.map(String.init) ?? "")|\(connection.identityFile ?? "")|\(connection.sshOptions.joined(separator: "\u{1f}"))"
    }
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
            command: "test -f \(escapedPath) && cat -- \(escapedPath)",
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
        private var terminationGate = ProcessTerminationGate()
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
                lock.lock()
                terminationGate.markFinished()
                lock.unlock()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            let shouldTerminateDeferredRequest = terminationGate.markLaunched()
            lock.unlock()
            if shouldTerminateDeferredRequest || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    lock.lock()
                    terminationGate.markFinished()
                    lock.unlock()
                    throw CancellationError()
                }
                process.terminate()
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            lock.lock()
            terminationGate.markFinished()
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
            let shouldTerminate = terminationGate.requestTermination()
            lock.unlock()

            guard shouldTerminate else {
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
        private var terminationGate = ProcessTerminationGate()
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
                lock.lock()
                terminationGate.markFinished()
                lock.unlock()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            let shouldTerminateDeferredRequest = terminationGate.markLaunched()
            lock.unlock()
            if shouldTerminateDeferredRequest || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    lock.lock()
                    terminationGate.markFinished()
                    lock.unlock()
                    throw CancellationError()
                }
                process.terminate()
            }

            try outPipe.fileHandleForReading.copyDataToEndOfFile(to: outputHandle)
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            lock.lock()
            terminationGate.markFinished()
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
            let shouldTerminate = terminationGate.requestTermination()
            lock.unlock()

            guard shouldTerminate else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private static func runSSHCommand(connection: SSHFileExplorerConnection, command: String) async throws -> String {
        let result = try await runSSHCommandResult(connection: connection, command: command)
        guard result.terminationStatus == 0 else {
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
        return result.stdout
    }

    /// Runs `command` and returns its exit status with the captured output, so
    /// callers can react to specific non-zero statuses. Only transport failures
    /// (spawn errors, cancellation) throw.
    private static func runSSHCommandResult(
        connection: SSHFileExplorerConnection,
        command: String
    ) async throws -> SSHCommandResult {
        let commandProcess = SSHCommandProcess(connection: connection, command: command)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }
    }

    private static func sshArguments(connection: SSHFileExplorerConnection, command: String) -> [String] {
        var args: [String] = SSHHostConfiguredRemoteCommand().overrideArguments
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
        let result = try await runSSHCommandResult(
            connection: connection,
            command: posixShellBootstrap(script: remoteListingScript(path: path, showHidden: showHidden))
        )
        if result.terminationStatus == 0 {
            return parseRemoteListing(result.stdout, path: path, showHidden: showHidden)
        }
        // Only a missing tool (`base64`, `find`, a usable `stat`) falls back to
        // the plain `ls` listing without dates. Access failures and dead
        // connections keep their error so the explorer does not retry against
        // an unreadable directory or an unreachable host.
        guard result.terminationStatus == remoteListingUnsupportedToolsStatus else {
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
        let output = try await runSSHCommand(
            connection: connection,
            command: legacyListingCommand(path: path, showHidden: showHidden)
        )
        return parseLegacyListing(output, path: path, showHidden: showHidden)
    }

    /// Exit status ``remoteListingScript(path:showHidden:)`` and
    /// ``posixShellBootstrap(script:)`` use when the remote host lacks a tool
    /// the dated listing needs. Distinct from `1` (unreadable or missing
    /// directory) so ``runSSHListCommand`` can fall back without masking access
    /// errors.
    static let remoteListingUnsupportedToolsStatus: Int32 = 3

    /// The pre-timestamp listing: POSIX `ls` with type suffixes. Used only when
    /// the dated script reports ``remoteListingUnsupportedToolsStatus``.
    static func legacyListingCommand(path: String, showHidden: Bool) -> String {
        let lsFlags = showHidden ? "-1paFA" : "-1paF"
        return "ls \(lsFlags) \(shellSingleQuote(path)) 2>/dev/null"
    }

    /// Parses ``legacyListingCommand(path:showHidden:)`` output. Entries carry
    /// no dates, so date sorts place them in the "unknown" group.
    static func parseLegacyListing(
        _ output: String,
        path: String,
        showHidden: Bool
    ) -> [FileExplorerEntry] {
        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let entry = String(line)
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
            return FileExplorerEntry(name: cleanName, path: normalizedPath + cleanName, isDirectory: isDir)
        }
    }

    /// POSIX `sh` script that lists `path` for the file explorer.
    ///
    /// It detects GNU vs BSD `stat` once, then enumerates the directory with
    /// `find ... -exec stat {} +`, which batches `stat` over the entries within
    /// the argument-size limit. The previous implementation spawned two or more
    /// `stat` processes per entry, which could make large remote directories
    /// appear to hang; a single glob of every entry would instead overflow
    /// `ARG_MAX` and truncate large listings. Timestamps are always collected
    /// so changing the sort key re-sorts the cached listing without a re-fetch.
    ///
    /// Access failures stay distinguishable from empty directories: an
    /// unreadable or missing directory (`cd` fails or `.` is not readable), a
    /// host without a usable `stat`, or a listing command that fails (`find`
    /// lacks `-mindepth`/`-maxdepth`, an unsupported `stat` format, or a
    /// per-entry error) exits non-zero via `|| exit 1` so `runSSHCommand` raises
    /// `sshCommandFailed` instead of masking the failure as an empty listing. A
    /// readable but genuinely empty directory makes `find` exit zero with no
    /// output and reaches the trailing `exit 0`, listing as empty.
    static func remoteListingScript(path: String, showHidden: Bool) -> String {
        let escapedPath = shellSingleQuote(path)
        // Exclude dotfiles unless hidden entries are requested. `find` never
        // yields `.`/`..` because it only descends from `.`.
        let nameFilter = showHidden ? "" : "! -name '.*' "
        // `stat` does NOT dereference symlinks (no `-L`): a following stat omits
        // dangling symlinks entirely on GNU, hiding them from the explorer. With
        // plain lstat every entry is listed, and symlinks report as their own
        // type — matching the previous `ls -F` behavior.
        //
        // Literal tabs separate the fields; GNU `stat -c` does not expand `\t`.
        return """
        cd \(escapedPath) 2>/dev/null || exit 1
        [ -r . ] || exit 1
        command -v find >/dev/null 2>&1 || exit \(remoteListingUnsupportedToolsStatus)
        if stat -c %Y / >/dev/null 2>&1; then
          find . -mindepth 1 -maxdepth 1 \(nameFilter)-exec stat -c '%A\t%Y\t%W\t%n' {} + 2>/dev/null || exit 1
        elif stat -f %m / >/dev/null 2>&1; then
          find . -mindepth 1 -maxdepth 1 \(nameFilter)-exec stat -f '%Sp\t%m\t%B\t%N' {} + 2>/dev/null || exit 1
        else
          exit \(remoteListingUnsupportedToolsStatus)
        fi
        exit 0
        """
    }

    /// Wraps a POSIX script so it runs under `/bin/sh`, independent of the
    /// remote account's login shell.
    ///
    /// OpenSSH runs the remote command through the user's login shell, and
    /// non-POSIX shells (fish, csh/tcsh) cannot parse `for`/`if`/`case` or
    /// `$(...)`. The script is base64-encoded so only `/bin/sh -c` plus a
    /// base64 payload — which contains no shell metacharacters — reaches the
    /// login shell. `base64 -d` (GNU/coreutils) falls back to `-D` (BSD/macOS).
    ///
    /// If neither decode works (no/incompatible `base64`), the decoded script is
    /// empty and the bootstrap exits with ``remoteListingUnsupportedToolsStatus``
    /// rather than running `eval ""` and reporting a silently empty directory.
    static func posixShellBootstrap(script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return "/bin/sh -c 'b=\(encoded); s=$(printf %s \"$b\" | base64 -d 2>/dev/null || printf %s \"$b\" | base64 -D 2>/dev/null); [ -n \"$s\" ] || exit \(remoteListingUnsupportedToolsStatus); eval \"$s\"'"
    }

    /// Parses the tab-separated output of ``remoteListingScript(path:showHidden:)``.
    ///
    /// Each line is `mode<TAB>mtime<TAB>btime<TAB>name`. The trailing `name`
    /// field is split last so names containing spaces survive. The leading mode
    /// string uses `stat`'s permission format (`d…`, `-…`, `l…`) so directory
    /// detection does not depend on localized file-type prose. `find .` reports
    /// each entry as `./name`, so only the final path component is kept.
    static func parseRemoteListing(
        _ output: String,
        path: String,
        showHidden: Bool
    ) -> [FileExplorerEntry] {
        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            let rawName = parts[3]
            let name = String(rawName.split(separator: "/").last ?? rawName)
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            guard showHidden || !name.hasPrefix(".") else { return nil }
            let isDirectory = parts[0].first == "d"
            return FileExplorerEntry(
                name: name,
                path: normalizedPath + name,
                isDirectory: isDirectory,
                creationDate: dateFromEpochString(String(parts[2]), minimumEpoch: birthTimeMinimumEpoch),
                modificationDate: dateFromEpochString(String(parts[1]))
            )
        }
    }

    /// Birth times below this epoch (≈1973-03-03) are treated as unknown; some
    /// filesystems report `0` or other small sentinels when birth time is
    /// unavailable.
    private static let birthTimeMinimumEpoch: TimeInterval = 100_000_000

    private static func dateFromEpochString(
        _ value: String,
        minimumEpoch: TimeInterval = 0
    ) -> Date? {
        guard let seconds = TimeInterval(value), seconds > 0, seconds >= minimumEpoch else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum FileExplorerError: LocalizedError {
    case providerUnavailable
    case sshCommandFailed(String)
    case remoteCommandFailed(String)
    case previewCapacity
    case remoteFileTooLarge

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
        case .sshCommandFailed:
            return String(localized: "fileExplorer.error.sshFailed", defaultValue: "SSH command failed")
        case .previewCapacity:
            return String(localized: "fileExplorer.preview.capacity", defaultValue: "Close a Cloud file preview and try again.")
        case .remoteFileTooLarge:
            return String(localized: "fileExplorer.error.cloudPreviewTooLarge", defaultValue: "Cloud file previews are limited to 1 MB.")
        case .remoteCommandFailed:
            return String(localized: "fileExplorer.error.remoteFailed", defaultValue: "Remote command failed")
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

/// Main-actor store for file-explorer presentation and loading state.
@MainActor
final class FileExplorerStore: ObservableObject {
    @Published var rootPath: String = ""
    @Published var rootNodes: [FileExplorerNode] = []
    @Published private(set) var isRootLoading: Bool = false
    @Published private(set) var gitStatusByPath: [String: GitFileStatus] = [:]
    @Published private(set) var contentRevision = 0
    private(set) var sortOptions: FileExplorerSortOptions
    private(set) var sortRevision = 0
    @Published private(set) var rootStatusMessage: String?
    private(set) var workspaceRootIdentity: UUID?

    var provider: FileExplorerProvider?

    /// Whether hidden files are shown. Set from FileExplorerState externally.
    var showHiddenFiles: Bool = false

    /// Watches the root directory for filesystem changes (local only).
    private var directoryWatcher: FileWatcher?
    private var directoryWatchTask: Task<Void, Never>?
    private var directoryWatchPath: String?

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

    /// Prefetch debounce schedulers keyed by path.
    private var prefetchSchedulers: [String: MainActorDeferredActionScheduler] = [:]

    var workspaceRootObservation: FileExplorerWorkspaceObservation?
    var remoteHomeResolutionTask: Task<Void, Never>?
    var remoteHomeResolutionKey: String?
    let cloudPreviewCache = CloudFilePreviewCache()
    private(set) var resourceContextID = UUID()
    private let sortSettings: FileExplorerSortSettings
    private let notificationCenter: NotificationCenter
    private var sortSettingsObserver: NSObjectProtocol?

    private let gitStatusProvider: GitStatusProvider
    private var gitStatusGeneration: UInt64 = 0

    init(
        sortDefaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        gitStatusProvider: GitStatusProvider = GitStatusProvider()
    ) {
        self.notificationCenter = notificationCenter
        self.gitStatusProvider = gitStatusProvider
        let sortSettings = FileExplorerSortSettings(defaults: sortDefaults, notificationCenter: notificationCenter)
        self.sortSettings = sortSettings
        self.sortOptions = sortSettings.resolvedOptions()
        self.sortSettingsObserver = notificationCenter.addObserver(
            forName: FileExplorerSortSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySortOptionsFromDefaults()
            }
        }
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
        workspaceRootIdentity = identity
        resetResourceContext()
        rootPath = ""
        updateDirectoryWatcher()
    }

    func setRootStatusMessage(_ message: String?) {
        guard rootStatusMessage != message else { return }
        rootStatusMessage = message
    }

    private func resetResourceContext(preservingNavigation: Bool = false) {
        resourceContextID = UUID()
        cancelRemoteHomeResolution()
        cancelAllLoads()
        if !preservingNavigation {
            selectedPath = nil; selectedPaths = []; expandedPaths = []
        }
        rootNodes = []; nodesByPath = [:]; gitStatusByPath = [:]
        contentRevision &+= 1
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
        resourceContextID = UUID()
        rootPath = path
        reload()
        refreshGitStatus()
        updateDirectoryWatcher()
    }

    func refreshGitStatus() {
        gitStatusGeneration &+= 1
        let generation = gitStatusGeneration, path = rootPath
        let context = resourceContextID, source = gitStatusProvider
        guard !path.isEmpty, provider?.isAvailable == true,
              provider is LocalFileExplorerProvider || provider is SSHFileExplorerProvider else {
            gitStatusByPath = [:]
            return
        }
        let connection = (provider as? SSHFileExplorerProvider)?.connection
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) {
                if let connection {
                    return source.fetchStatusSSH(directory: path, destination: connection.destination,
                        port: connection.port, identityFile: connection.identityFile, sshOptions: connection.sshOptions)
                }
                return source.fetchStatus(directory: path)
            }.value
            guard let self, self.gitStatusGeneration == generation, self.resourceContextID == context else { return }
            self.gitStatusByPath = status
        }
    }

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

    func setProvider(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        #if DEBUG
        NSLog("[FileExplorer] setProvider: \(type(of: newProvider).self) available=\(newProvider?.isAvailable ?? false)")
        #endif
        let providerChanged: Bool
        switch (provider, newProvider) {
        case let (current?, next?): providerChanged = current !== next
        case (nil, nil): providerChanged = false
        default: providerChanged = true
        }
        if providerChanged { resetResourceContext(preservingNavigation: true) }
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
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory else { return }
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

    func setSortKey(_ key: FileExplorerSortKey) {
        let nextOrder: FileExplorerSortOrder = sortOptions.key == .name && key != .name
            ? .descending
            : sortOptions.order
        setSortOptions(FileExplorerSortOptions(key: key, order: nextOrder))
    }

    func setSortOrder(_ order: FileExplorerSortOrder) {
        setSortOptions(FileExplorerSortOptions(key: sortOptions.key, order: order))
    }

    func setSortOptions(_ options: FileExplorerSortOptions) {
        applySortOptions(options, persist: true)
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
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory else { return }
        selectedPath = node.path
        selectedPaths = [node.path]
        pendingDescendIntoFirstChildPath = node.path
        expand(node: node)
    }

    func prefetchChildren(for node: FileExplorerNode) {
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory, node.children == nil, !loadingPaths.contains(node.path) else { return }
        // Debounce: only prefetch if hover persists for 200ms
        let path = node.path
        let scheduler = prefetchSchedulers[path] ?? MainActorDeferredActionScheduler()
        prefetchSchedulers[path] = scheduler
        scheduler.schedule(after: .milliseconds(200)) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, node.children == nil, !self.loadingPaths.contains(path) else { return }
                // Silent prefetch: don't show loading indicator
                await self.loadChildren(for: node, at: path, silent: true)
            }
        }
    }

    func cancelPrefetch(for node: FileExplorerNode) {
        prefetchSchedulers[node.path]?.cancel()
        prefetchSchedulers.removeValue(forKey: node.path)
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
        guard parentNode?.resourceContextID == nil || parentNode?.resourceContextID == resourceContextID else { return }
        // A load cancelled by cancelAllLoads (e.g. a root reload during an SSH provider swap) must not
        // reach provider.listDirectory: the provider may have been replaced, so a stale in-flight load
        // would list the old path through the new transport. Bail before any listing.
        guard !Task.isCancelled else { return }
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
                let node = FileExplorerNode(
                    name: entry.name,
                    path: entry.path,
                    isDirectory: entry.isDirectory,
                    creationDate: entry.creationDate,
                    modificationDate: entry.modificationDate
                )
                node.resourceContextID = resourceContextID
                nodesByPath[entry.path] = node
                return node
            }.sorted(using: sortOptions)

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
        for scheduler in prefetchSchedulers.values {
            scheduler.cancel()
        }
        prefetchSchedulers.removeAll()
        isRootLoading = false
    }

    private func applySortOptionsFromDefaults() {
        applySortOptions(sortSettings.resolvedOptions(), persist: false)
    }

    private func applySortOptions(_ options: FileExplorerSortOptions, persist: Bool) {
        guard sortOptions != options else { return }; objectWillChange.send()
        sortOptions = options
        resortLoadedNodes()
        sortRevision &+= 1
        if persist {
            sortSettings.setOptions(options)
        }
    }

    private func resortLoadedNodes() {
        rootNodes = sortNodes(rootNodes)
        for node in nodesByPath.values {
            if let children = node.children {
                node.children = sortNodes(children)
            }
        }
    }

    private func sortNodes(_ nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        FileExplorerNodeSorter(options: sortOptions).sorted(nodes)
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
        if let sortSettingsObserver {
            notificationCenter.removeObserver(sortSettingsObserver)
        }
        remoteHomeResolutionTask?.cancel()
        directoryWatchTask?.cancel()
    }
}

private extension Array where Element == FileExplorerNode {
    func sorted(using options: FileExplorerSortOptions) -> [FileExplorerNode] {
        FileExplorerNodeSorter(options: options).sorted(self)
    }
}
