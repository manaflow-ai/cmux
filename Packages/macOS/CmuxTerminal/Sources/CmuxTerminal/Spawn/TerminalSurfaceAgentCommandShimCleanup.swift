public import Foundation
public import CmuxFoundation

/// Removes per-surface agent command shim directories nothing can use any more.
///
/// Every terminal surface gets `<root>/cmux-cli-shims/<surface id>` at the
/// front of its `PATH`. The directory is only useful while the pane is open,
/// so it goes when the pane closes for good, and
/// ``TerminalSurfaceAgentCommandShimSweep`` collects the ones a crash, a
/// forced quit or an older build left behind.
///
/// The root is shared by every cmux on the machine (stable, nightly and tagged
/// builds), so neither can go by one app's open surfaces. Each directory
/// instead records every cmux process that installed it, and stays while one
/// of them runs. Two can share a directory: a session restored from another
/// channel keeps its surface ids. The shell in a pane cannot answer the
/// question itself: macOS does not show one process the environment of
/// another when that other is a system binary, and `zsh` is one.
///
/// ```swift
/// let cleanup = TerminalSurfaceAgentCommandShimCleanup(rootDirectory: root)
/// cleanup.removeShimDirectory(surfaceId: closedSurface)
/// ```
public struct TerminalSurfaceAgentCommandShimCleanup {
    /// The directory under the shim root that holds one directory per surface.
    public static let shimParentDirectoryName = "cmux-cli-shims"

    /// The prefix of the files in a shim directory that each name one process
    /// that installed it; the process id follows.
    public static let ownerRecordFilePrefix = ".owner."

    /// How many owner records a directory is read for. Two is already rare.
    private static let ownerRecordLimit = 16

    /// The directory that holds one shim directory per surface.
    public let shimParentDirectory: URL

    private let owner: AgentPIDProcessIdentity?
    private let ownerIsRunning: (AgentPIDProcessIdentity) -> Bool
    private let fileManager: FileManager

    /// Creates a cleanup for the shim directories under `rootDirectory`.
    ///
    /// - Parameters:
    ///   - rootDirectory: The durable shim root surfaces install under.
    ///   - owner: The process that installs and closes on behalf of this
    ///     value; this process by default.
    ///   - ownerIsRunning: Whether a recorded installer is still that
    ///     process. By default the kernel is asked, and the same process id
    ///     with another start time counts as gone.
    ///   - fileManager: The file manager that lists, moves and removes.
    public init(
        rootDirectory: URL,
        owner: AgentPIDProcessIdentity? = AgentPIDProcessIdentity(pid: getpid()),
        ownerIsRunning: @escaping (AgentPIDProcessIdentity) -> Bool = { AgentPIDProcessIdentity(pid: $0.pid) == $0 },
        fileManager: FileManager = .default
    ) {
        self.shimParentDirectory = rootDirectory
            .appendingPathComponent(Self.shimParentDirectoryName, isDirectory: true)
            .standardizedFileURL
        self.owner = owner
        self.ownerIsRunning = ownerIsRunning
        self.fileManager = fileManager
    }

    // MARK: Closing a surface

    /// Gives up the owner's claim on a surface's shim directory, and removes
    /// the directory when no other running cmux has one.
    ///
    /// - Parameter surfaceId: The surface whose pane has closed for good.
    /// - Returns: `true` when the directory was removed.
    @discardableResult
    public func removeShimDirectory(surfaceId: UUID) -> Bool {
        let directory = shimParentDirectory.appendingPathComponent(surfaceId.uuidString, isDirectory: true)
        guard isOwnedDirectory(shimParentDirectory), isOwnedDirectory(directory) else { return false }
        // Not waited for: this runs where the pane closes, on the main
        // actor. A directory left behind goes with a later sweep.
        guard let lock = DirectoryLock(shimParentDirectory: shimParentDirectory) else { return false }
        defer { withExtendedLifetime(lock) {} }
        var owners = ownerRecords(inDirectory: directory)
        if let owner {
            // Without the owner's record the directory is no longer the one
            // it installed: something replaced it since, such as a cmux older
            // than the records that holds the same surface. That is the
            // sweep's to judge.
            guard owners.contains(owner) else { return false }
            try? fileManager.removeItem(at: ownerRecordURL(inDirectory: directory, pid: owner.pid))
            owners.removeAll { $0 == owner }
        }
        guard !owners.contains(where: ownerIsRunning) else { return false }
        return removeOwnedDirectory(directory)
    }

    // MARK: Owner records

    /// Records the owner as a process that installed the shims in `directory`.
    ///
    /// - Parameter directory: A shim directory being installed.
    /// - Returns: `true` when the record was written.
    @discardableResult
    public func writeOwnerRecord(inDirectory directory: URL) -> Bool {
        guard let owner else { return false }
        return write(owner, inDirectory: directory)
    }

    /// Reads the processes recorded as installers of the shims in `directory`.
    ///
    /// - Parameter directory: A shim directory.
    /// - Returns: The recorded processes; none for a directory an older
    ///   build or a shell integration made.
    public func ownerRecords(inDirectory directory: URL) -> [AgentPIDProcessIdentity] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return entries.lazy
            .filter { $0.hasPrefix(Self.ownerRecordFilePrefix) }
            .sorted()
            .prefix(Self.ownerRecordLimit)
            .compactMap { ownerRecord(at: directory.appendingPathComponent($0, isDirectory: false)) }
    }

    /// Records who owns the shims an install is about to publish.
    ///
    /// The owner is recorded in `stagingDirectory`, together with every other
    /// cmux process that still runs and had a record in the directory being
    /// replaced, so a cmux that restored the same surface keeps its claim.
    ///
    /// - Parameters:
    ///   - stagingDirectory: The directory about to be published.
    ///   - publishedDirectory: The directory it replaces, if there is one.
    func recordOwners(inStagingDirectory stagingDirectory: URL, replacing publishedDirectory: URL) {
        for other in ownerRecords(inDirectory: publishedDirectory) where other != owner && ownerIsRunning(other) {
            write(other, inDirectory: stagingDirectory)
        }
        writeOwnerRecord(inDirectory: stagingDirectory)
    }

    @discardableResult
    private func write(_ owner: AgentPIDProcessIdentity, inDirectory directory: URL) -> Bool {
        let record = "\(owner.pid) \(owner.startSeconds) \(owner.startMicroseconds)\n"
        let recordURL = ownerRecordURL(inDirectory: directory, pid: owner.pid)
        return (try? Data(record.utf8).write(to: recordURL, options: [.atomic])) != nil
    }

    private func ownerRecordURL(inDirectory directory: URL, pid: pid_t) -> URL {
        directory.appendingPathComponent("\(Self.ownerRecordFilePrefix)\(pid)", isDirectory: false)
    }

    private func ownerRecord(at recordURL: URL) -> AgentPIDProcessIdentity? {
        // A record is three short numbers; anything larger is not one.
        guard let attributes = try? fileManager.attributesOfItem(atPath: recordURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 128,
              let data = try? Data(contentsOf: recordURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3,
              let pid = pid_t(fields[0]), pid > 0,
              let startSeconds = Int64(fields[1]),
              let startMicroseconds = Int64(fields[2]) else {
            return nil
        }
        return AgentPIDProcessIdentity(
            pid: pid,
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
    }

    // MARK: Publishing and sweeping one at a time

    /// The lock that keeps one cmux from publishing a shim directory while
    /// another sweeps or closes it.
    ///
    /// A restored surface keeps its id, so at launch an install and a sweep
    /// can reach the same stale directory together. Without the lock the
    /// install can find its directory gone halfway through and give up, which
    /// leaves that pane without shims.
    ///
    /// The kernel releases the lock when its holder exits, however it exits.
    /// A holder can also be stopped while it holds the lock, so nobody waits
    /// for it without a bound.
    public final class DirectoryLock {
        private let descriptor: Int32

        /// Takes the lock for the shim directories under `shimParentDirectory`.
        ///
        /// - Parameters:
        ///   - shimParentDirectory: The directory that holds one directory
        ///     per surface. It must already exist.
        ///   - patience: How long to keep trying while another process holds
        ///     the lock. Zero tries once.
        /// - Returns: `nil` when the lock cannot be taken in that time.
        public init?(shimParentDirectory: URL, waitingUpTo patience: Duration = .zero) {
            let path = shimParentDirectory.appendingPathComponent(".lock", isDirectory: false).path
            let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { return nil }
            // flock has no timed wait, so a bounded wait is a few spaced
            // attempts. A holder keeps the lock for one rename or one
            // removal, well under an interval.
            let interval = Duration.milliseconds(10)
            let deadline = ContinuousClock.now + patience
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let failure = errno
                guard ContinuousClock.now < deadline, failure == EINTR || failure == EWOULDBLOCK else {
                    close(descriptor)
                    return nil
                }
                if failure == EWOULDBLOCK {
                    var pause = timespec(tv_sec: 0, tv_nsec: Int(interval.components.attoseconds / 1_000_000_000))
                    nanosleep(&pause, nil)
                }
            }
            self.descriptor = descriptor
        }

        deinit {
            close(descriptor)
        }
    }

    // MARK: Sweeping

    /// Removes shim directories whose pane is gone.
    ///
    /// A directory is removed when nothing has written to it since `cutoff`,
    /// no running process names it, and no process that installed it still
    /// runs. A directory with no owner record was made by a build older than
    /// the records or by a shell integration, and may belong to a pane in
    /// another cmux that is still open; the caller says whether such a cmux
    /// could be running.
    ///
    /// Only directories this code can have created are considered: a surface
    /// id, a shell process id (the shell integrations' fallback name) or a
    /// directory an interrupted install or sweep left behind. A symlink, a
    /// file or a directory another user owns is left alone.
    ///
    /// Another cmux can install into a directory while this runs, for a
    /// restored surface that keeps its id. Each removal therefore holds the
    /// ``DirectoryLock`` an install publishes under. For writers that do not
    /// take it, the directory is also moved aside first and checked again,
    /// and put back if it is in use after all.
    ///
    /// - Parameters:
    ///   - inUseDirectoryNames: Directory names some running process still
    ///     has in its environment.
    ///   - cutoff: A directory written to after this date is kept.
    ///   - removesDirectoriesWithoutOwnerRecord: Whether a directory with no
    ///     owner record may go. Pass `false` while another cmux is running.
    /// - Returns: The names of the directories removed.
    @discardableResult
    public func removeUnusedShimDirectories(
        inUseDirectoryNames: Set<String>,
        unusedSince cutoff: Date,
        removesDirectoriesWithoutOwnerRecord: Bool
    ) -> [String] {
        guard isOwnedDirectory(shimParentDirectory),
              let names = try? fileManager.contentsOfDirectory(atPath: shimParentDirectory.path) else {
            return []
        }
        var removed: [String] = []
        for name in names {
            guard let kind = managedDirectoryKind(name), !inUseDirectoryNames.contains(name) else {
                continue
            }
            let directory = shimParentDirectory.appendingPathComponent(name, isDirectory: true)
            func isUnused(_ location: URL) -> Bool {
                guard let lastWrite = lastWriteDate(of: location), lastWrite < cutoff else { return false }
                guard kind == .surface else { return true }
                let owners = ownerRecords(inDirectory: location)
                guard !owners.isEmpty else { return removesDirectoriesWithoutOwnerRecord }
                return !owners.contains(where: ownerIsRunning)
            }
            guard isUnused(directory) else { continue }
            // Taken per directory, so a sweep of many never holds up a pane
            // that is starting. Without the lock this one waits for the next
            // launch.
            guard let lock = DirectoryLock(shimParentDirectory: shimParentDirectory) else { continue }
            defer { withExtendedLifetime(lock) {} }
            guard isUnused(directory), isOwnedDirectory(directory) else { continue }

            // A cmux older than the lock, or a shell integration, can still
            // write here. One rename: such a writer either finds the
            // directory gone and creates it again, or has already written to
            // it, in which case the directory moved aside goes back.
            let holdingDirectory = shimParentDirectory
                .appendingPathComponent(".sweep.\(UUID().uuidString)", isDirectory: true)
            guard (try? fileManager.moveItem(at: directory, to: holdingDirectory)) != nil else {
                continue
            }
            if !isUnused(holdingDirectory) {
                if (try? fileManager.moveItem(at: holdingDirectory, to: directory)) != nil {
                    continue
                }
                // The name is taken only when a newer install replaced this
                // one. Otherwise leave it for a later sweep rather than
                // delete a directory just found in use.
                guard fileManager.fileExists(atPath: directory.path) else { continue }
            }
            if removeOwnedDirectory(holdingDirectory) {
                removed.append(name)
            }
        }
        return removed
    }

    private enum ManagedDirectoryKind {
        /// A surface id, or the shell process id a shell integration falls back to.
        case surface
        /// What an interrupted install or sweep left behind; never anyone's `PATH` entry.
        case leftover
    }

    /// Classifies `name` when it is one the installer, a shell integration or
    /// the sweep creates.
    private func managedDirectoryKind(_ name: String) -> ManagedDirectoryKind? {
        if UUID(uuidString: name) != nil { return .surface }
        if !name.isEmpty, name.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            return .surface
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.first?.isEmpty == true else { return nil }
        // `.<surface id>.staging.<install id>`, left by an interrupted install.
        if parts.count == 4,
           UUID(uuidString: String(parts[1])) != nil,
           parts[2] == "staging",
           UUID(uuidString: String(parts[3])) != nil {
            return .leftover
        }
        // `.sweep.<sweep id>`, left by an interrupted sweep.
        if parts.count == 3, parts[1] == "sweep", UUID(uuidString: String(parts[2])) != nil {
            return .leftover
        }
        return nil
    }

    /// The most recent write to the directory or to an entry directly in it.
    ///
    /// The app replaces the whole directory when it installs, but a shell
    /// integration rewrites `claude` in place, which leaves the directory's
    /// own date alone.
    private func lastWriteDate(of directory: URL) -> Date? {
        guard var latest = modificationDate(atPath: directory.path),
              let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        for entry in entries {
            let path = directory.appendingPathComponent(entry, isDirectory: false).path
            if let date = modificationDate(atPath: path), date > latest {
                latest = date
            }
        }
        return latest
    }

    private func modificationDate(atPath path: String) -> Date? {
        // attributesOfItem does not follow a symlink in the last component.
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Whether `directory` is a real directory this user owns, not a symlink.
    private func isOwnedDirectory(_ directory: URL) -> Bool {
        PrivateDirectoryCheck().makePrivate(atPath: directory.path)
    }

    private func removeOwnedDirectory(_ directory: URL) -> Bool {
        // Checked again right before removal: the root is shared between
        // every cmux process of this user.
        guard isOwnedDirectory(directory) else { return false }
        return (try? fileManager.removeItem(at: directory)) != nil
    }
}
