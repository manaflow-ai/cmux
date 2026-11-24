public import Foundation

/// Removes the per-surface command shim directories whose pane is gone.
///
/// A pane removes its own directory when it closes. This collects what that
/// misses: panes that went with a crash or a forced quit, and the directories
/// builds before the close-time removal left behind. The app runs it once per
/// launch, off the main actor.
///
/// Stable, nightly and tagged builds share one shim root. A directory stays
/// while a cmux that installed it runs, while some process still names it, and
/// for ``unusedLifetime`` after its last write; see
/// ``TerminalSurfaceAgentCommandShimCleanup`` for the rules. This type decides
/// what the running processes say about those rules. The app supplies the
/// process table, which is all it needs from the kernel.
///
/// ```swift
/// let sweep = TerminalSurfaceAgentCommandShimSweep(
///     cleanup: TerminalSurfaceAgentCommandShimCleanup(rootDirectory: root),
///     processTable: { readProcessTable() }
/// )
/// sweep.sweep()
/// ```
public struct TerminalSurfaceAgentCommandShimSweep {
    /// One of this user's running processes, as far as the kernel shows it.
    public struct RunningProcess {
        /// The process id.
        public let processID: Int
        /// The short process name.
        public let name: String
        /// The executable the process runs, or `nil` when the kernel will not
        /// say, as for an app whose bundle was replaced while it runs.
        public let executablePath: String?
        /// The values of the process's environment, or `nil` when they cannot
        /// be read. System binaries such as `zsh` never show theirs.
        public let environmentValues: [String]?

        /// Creates a process description.
        public init(processID: Int, name: String, executablePath: String?, environmentValues: [String]?) {
            self.processID = processID
            self.name = name
            self.executablePath = executablePath
            self.environmentValues = environmentValues
        }
    }

    /// This user's running processes at one moment.
    public struct ProcessTable {
        /// The processes, this one included.
        public let processes: [RunningProcess]
        /// Whether ``processes`` covers every process the user runs.
        public let isComplete: Bool

        /// Creates a process table.
        public init(processes: [RunningProcess], isComplete: Bool) {
            self.processes = processes
            self.isComplete = isComplete
        }
    }

    /// What one sweep did.
    public enum Outcome: Equatable, Sendable {
        /// Nothing was removed: without a trustworthy process table, every
        /// directory might be one some process still uses.
        case skippedUnreadableProcessTable
        /// The sweep ran.
        ///
        /// - Parameters:
        ///   - removed: The names of the directories removed.
        ///   - namedByProcesses: How many directory names running processes
        ///     still had in their environment.
        ///   - anotherCmuxIsRunning: Whether another cmux app was running,
        ///     which keeps every directory that has no owner record.
        case swept(removed: [String], namedByProcesses: Int, anotherCmuxIsRunning: Bool)
    }

    /// How long a directory nobody owns is kept after its last write.
    public let unusedLifetime: TimeInterval

    private let cleanup: TerminalSurfaceAgentCommandShimCleanup
    private let currentProcessID: Int
    private let processTable: () -> ProcessTable
    private let fileExists: (String) -> Bool

    /// Creates a sweep.
    ///
    /// - Parameters:
    ///   - cleanup: The cleanup for the shim root to sweep.
    ///   - unusedLifetime: How long a directory nobody owns is kept after its
    ///     last write.
    ///   - currentProcessID: This process.
    ///   - processTable: Reads this user's running processes.
    ///   - fileExists: Whether a file exists at a path.
    public init(
        cleanup: TerminalSurfaceAgentCommandShimCleanup,
        unusedLifetime: TimeInterval = 24 * 60 * 60,
        currentProcessID: Int = Int(getpid()),
        processTable: @escaping () -> ProcessTable,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.cleanup = cleanup
        self.unusedLifetime = unusedLifetime
        self.currentProcessID = currentProcessID
        self.processTable = processTable
        self.fileExists = fileExists
    }

    /// Removes the shim directories nothing uses any more.
    ///
    /// - Parameter now: The current date.
    /// - Returns: What the sweep did.
    @discardableResult
    public func sweep(now: Date = Date()) -> Outcome {
        let table = processTable()
        guard let inUseDirectoryNames = directoryNamesInUse(in: table) else {
            return .skippedUnreadableProcessTable
        }
        let anotherCmuxIsRunning = anotherCmuxIsRunning(in: table)
        let removed = cleanup.removeUnusedShimDirectories(
            inUseDirectoryNames: inUseDirectoryNames,
            unusedSince: now.addingTimeInterval(-unusedLifetime),
            removesDirectoriesWithoutOwnerRecord: !anotherCmuxIsRunning
        )
        return .swept(
            removed: removed,
            namedByProcesses: inUseDirectoryNames.count,
            anotherCmuxIsRunning: anotherCmuxIsRunning
        )
    }

    /// The shim directory names the running processes still name.
    ///
    /// A surface's directory shows up as a `PATH` entry and in the wrapper's
    /// shim variables, and both survive in every process the surface's shell
    /// started, including a `tmux` server or an agent that outlives the pane.
    ///
    /// The answer keeps directories from the sweep, so it is only given when
    /// it can be trusted: the table has to be whole, and this process has to
    /// be able to read at least its own environment. A process whose
    /// environment cannot be read is skipped, which is why this only adds to
    /// what owner records protect.
    private func directoryNamesInUse(in table: ProcessTable) -> Set<String>? {
        guard table.isComplete else { return nil }
        let marker = "/\(TerminalSurfaceAgentCommandShimCleanup.shimParentDirectoryName)/"
        var names: Set<String> = []
        var readCurrentProcess = false
        for process in table.processes {
            guard let values = process.environmentValues else { continue }
            if process.processID == currentProcessID {
                readCurrentProcess = true
            }
            for value in values {
                var remainder = value[...]
                while let range = remainder.range(of: marker) {
                    let tail = remainder[range.upperBound...]
                    let name = tail.prefix { $0 != "/" && $0 != ":" }
                    if !name.isEmpty {
                        names.insert(String(name))
                    }
                    remainder = tail
                }
            }
        }
        return readCurrentProcess ? names : nil
    }

    /// Whether another cmux app is running.
    ///
    /// A directory with no owner record may belong to an open pane of such an
    /// app. A cmux app is recognised by what makes it install shims, the
    /// wrapper in its bundle, rather than by bundle identifier, so every
    /// build and tag counts. Helpers do not, inside the bundle or in an app
    /// of their own. A bundle can be deleted or replaced while its app runs,
    /// and the kernel then stops reporting where it runs from, so a process
    /// named as the app's executable is (`cmux`, `cmux DEV`) counts with or
    /// without its wrapper.
    private func anotherCmuxIsRunning(in table: ProcessTable) -> Bool {
        let marker = ".app/Contents/MacOS/"
        for process in table.processes where process.processID != currentProcessID {
            let isNamedLikeCmux = process.name == "cmux" || process.name.hasPrefix("cmux ")
            guard let path = process.executablePath else {
                if isNamedLikeCmux { return true }
                continue
            }
            guard let range = path.range(of: marker, options: .backwards),
                  !path[range.upperBound...].contains("/") else {
                continue
            }
            if isNamedLikeCmux
                || fileExists(path[..<range.lowerBound] + ".app/Contents/Resources/bin/cmux-claude-wrapper") {
                return true
            }
        }
        return false
    }
}
