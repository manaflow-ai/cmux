import Darwin
import Foundation

/// A wrapper-owned private directory of queued hook events for one agent session.
///
/// The shell producer (``AgentHookSpoolProducer``) publishes each event as a
/// `*.rec` file, and one forwarder per session admits them to the app's ordered
/// hook queue. Ownership of a published record is decided by `unlink(2)`:
/// whichever process removes the file owns the event. A drainer reads, then
/// unlinks, and admits only records it removed. A producer that finds no live
/// forwarder unlinks its own record before falling back to the CLI. Every
/// event is therefore admitted at most once, as with the CLI admission it
/// replaces.
///
/// Records are named `<seconds>.<nanoseconds>-<pid>.rec` from the producer's
/// clock. Hooks for sequential agent events run one after another, so name
/// order is publication order for every pair of events whose order is defined.
///
/// ```swift
/// let spool = AgentHookSpoolDirectory(url: URL(fileURLWithPath: path))
/// for name in spool.publishedRecordNames() {
///     if let record = spool.claim(name: name) { admit(record) }
/// }
/// ```
public struct AgentHookSpoolDirectory: Sendable {
    /// Write-locked by the live forwarder for its whole lifetime.
    public static let forwarderLockName = "forwarder.lock"
    /// Write-locked by whichever process is claiming and admitting records.
    public static let drainLockName = "drain.lock"
    /// Environment key names the producer captures, one per line.
    public static let environmentKeysName = "keys"
    /// The published record suffix. `*.tmp` files are still being written.
    public static let recordSuffix = ".rec"
    /// The largest record file a drainer reads.
    public static let maximumRecordBytes = 512 * 1_024

    /// The spool directory.
    public let url: URL

    /// Creates a view of one spool directory.
    ///
    /// - Parameter url: A directory created by the agent wrapper with mode 0700.
    public init(url: URL) {
        self.url = url
    }

    /// Reports whether the directory is a real directory owned by this user
    /// and closed to group and other access.
    public func isPrivate() -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == getuid()
            && info.st_mode & 0o077 == 0
    }

    /// Creates the forwarder and drain lock files.
    ///
    /// - Returns: Whether both files exist in a private directory.
    public func createLockFiles() -> Bool {
        guard isPrivate() else { return false }
        for name in [Self.forwarderLockName, Self.drainLockName] {
            let fd = open(url.appendingPathComponent(name).path,
                          O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return false }
            Darwin.close(fd)
        }
        return true
    }

    /// Publishes the environment key list, which enables the producer.
    ///
    /// The producer falls back to the CLI until this file exists, so the
    /// forwarder calls this only after it holds ``forwarderLockName``.
    ///
    /// - Parameter keys: Names of hook environment values to capture.
    /// - Returns: Whether the list was written.
    public func publishEnvironmentKeys(_ keys: [String]) -> Bool {
        let text = keys.filter(Self.isEnvironmentKey).joined(separator: "\n") + "\n"
        let pending = url.appendingPathComponent("\(Self.environmentKeysName).tmp")
        let fd = open(pending.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        Darwin.close(fd)
        guard written == bytes.count else { unlink(pending.path); return false }
        return rename(pending.path, url.appendingPathComponent(Self.environmentKeysName).path) == 0
    }

    /// Returns published record names in publication order.
    public func publishedRecordNames() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return []
        }
        return names.compactMap { name in
            AgentHookSpoolRecordName(name).map { (order: $0, name: name) }
        }
        .sorted { $0.order < $1.order }
        .map(\.name)
    }

    /// Claims one published record by removing it from the directory.
    ///
    /// Callers must hold ``drainLockName`` so claims and admissions from two
    /// drainers do not interleave.
    ///
    /// - Parameter name: A name returned by ``publishedRecordNames()``.
    /// - Returns: The decoded record when this call removed it; `nil` when
    ///   another process claimed it first or the record is malformed.
    public func claim(name: String) -> AgentHookSpoolRecord? {
        guard AgentHookSpoolRecordName(name) != nil else { return nil }
        let path = url.appendingPathComponent(name).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        var bytes: [UInt8] = []
        if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
           info.st_size > 0, info.st_size <= Self.maximumRecordBytes {
            bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count != bytes.count { bytes = [] }
        }
        Darwin.close(fd)
        // The unlink is the claim. A producer that reclaimed its own record
        // first wins, and this drainer must not admit a second copy.
        guard unlink(path) == 0, !bytes.isEmpty else { return nil }
        return AgentHookSpoolRecord(data: Data(bytes))
    }

    /// Takes a write lock on one of the spool's lock files.
    ///
    /// The lock is a `fcntl(2)` record lock because the shell producer probes
    /// ``forwarderLockName`` with zsh's `zsystem flock`, which uses the same
    /// primitive. The kernel releases it when the holder exits.
    ///
    /// - Parameters:
    ///   - name: ``forwarderLockName`` or ``drainLockName``.
    ///   - blocking: Whether to wait for another holder.
    /// - Returns: The held lock, released on deallocation, or `nil` when the
    ///   file is missing or another process holds it.
    public func lock(_ name: String, blocking: Bool) -> AgentHookSpoolLock? {
        let fd = open(url.appendingPathComponent(name).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var region = flock()
        region.l_type = Int16(F_WRLCK)
        region.l_whence = Int16(SEEK_SET)
        while fcntl(fd, blocking ? F_SETLKW : F_SETLK, &region) != 0 {
            if blocking, errno == EINTR { continue }
            Darwin.close(fd)
            return nil
        }
        return AgentHookSpoolLock(fileDescriptor: fd)
    }

    /// Moves the spool aside so producers can no longer publish into it.
    ///
    /// A producer that loses this race cannot write or rename its record and
    /// falls back to the CLI. A record published before the move stays in the
    /// returned directory for the forwarder's final drain.
    ///
    /// - Returns: The moved directory, or `nil` when the rename failed.
    public func retire() -> AgentHookSpoolDirectory? {
        let retired = retiredLocation
        guard rename(url.path, retired.url.path) == 0 else { return nil }
        return retired
    }

    /// Where ``retire()`` moves this spool for the forwarder's final drain.
    public var retiredLocation: AgentHookSpoolDirectory {
        AgentHookSpoolDirectory(
            url: url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).retired")
        )
    }

    /// Removes startup artifacts only when no key list or published records
    /// exist. Callers must hold the forwarder lifetime lock.
    /// A prior key list or record belongs to recovery, even if this start failed.
    public func removeIfUninitialized() {
        guard isPrivate(), let drainLock = lock(Self.drainLockName, blocking: true) else { return }
        withExtendedLifetime(drainLock) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                  !names.contains(Self.environmentKeysName),
                  !names.contains(where: { $0.hasSuffix(Self.recordSuffix) }) else { return }
            // Do not recursively remove unknown content or follow keys.tmp if
            // publication failed because it was a symlink.
            for name in [Self.forwarderLockName, Self.drainLockName, "\(Self.environmentKeysName).tmp"] {
                unlink(url.appendingPathComponent(name).path)
            }
            rmdir(url.path)
        }
    }

    /// Removes this protocol's files and the directory after the final drain.
    public func removeAll() {
        guard isPrivate(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return
        }
        let owned: Set<String> = [
            Self.forwarderLockName, Self.drainLockName,
            Self.environmentKeysName, "\(Self.environmentKeysName).tmp",
        ]
        for name in names where owned.contains(name)
            || name.hasSuffix(Self.recordSuffix) || name.hasSuffix(".tmp") {
            unlink(url.appendingPathComponent(name).path)
        }
        rmdir(url.path)
    }

    private static func isEnvironmentKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 128 && key.allSatisfy {
            $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_")
        }
    }
}
