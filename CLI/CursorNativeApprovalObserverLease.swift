import Darwin
import Foundation

/// Owns one cross-process slot for a detached Cursor approval observer.
struct CursorNativeApprovalObserverLease: Sendable {
    static let maximumConcurrentObserversPerProcess = 8

    private static let staleLeaseAge: TimeInterval = 30
    private static let maximumLeaseRecordBytes = 512
    private static let lockFileName = ".observer-leases.lock"

    let processIdentity: AgentPIDProcessIdentity
    let slotIndex: Int
    let leaseID: String
    let observationID: String
    private let rootDirectory: URL

    /// Claims one bounded slot before the detached observer is spawned.
    static func claim(
        processIdentity: AgentPIDProcessIdentity,
        observationID: String
    ) -> Self? {
        claim(
            processIdentity: processIdentity,
            observationID: observationID,
            rootDirectory: defaultRootDirectory
        )
    }

    /// Claims one bounded slot under an explicit root directory.
    static func claim(
        processIdentity: AgentPIDProcessIdentity,
        observationID: String,
        rootDirectory: URL
    ) -> Self? {
        guard let observationID = AgentAttentionOpaqueIdentifier(
            rawValue: observationID
        )?.rawValue else {
            return nil
        }
        let rootDirectory = rootDirectory.standardizedFileURL
        guard let lockDescriptor = acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return nil
        }
        defer { releaseRootLock(lockDescriptor) }

        let generationDirectory = generationDirectoryURL(
            processIdentity: processIdentity,
            rootDirectory: rootDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: generationDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            return nil
        }

        for slotIndex in 0 ..< maximumConcurrentObserversPerProcess {
            let slotURL = generationDirectory.appendingPathComponent(
                "slot-\(slotIndex)",
                isDirectory: false
            )
            if let record = readLeaseRecord(at: slotURL),
               record.observationID == observationID,
               !isStaleLeaseFile(at: slotURL) {
                return nil
            }
        }
        for slotIndex in 0 ..< maximumConcurrentObserversPerProcess {
            let lease = Self(
                processIdentity: processIdentity,
                slotIndex: slotIndex,
                leaseID: UUID().uuidString.lowercased(),
                observationID: observationID,
                rootDirectory: rootDirectory
            )
            if isStaleLeaseFile(at: lease.slotURL) {
                let childProcessIdentity = readLeaseRecord(
                    at: lease.slotURL
                )?.childProcessIdentity
                if childProcessIdentity.map({
                    AgentPIDProcessIdentity(
                        agentTurnPID: Int($0.pid)
                    ) == $0
                }) != true {
                    _ = unlink(lease.slotURL.path)
                }
            }
            if createLeaseFile(
                at: lease.slotURL,
                contents: lease.serializedRecord(childProcessIdentity: nil)
            ) {
                return lease
            }
        }
        return nil
    }

    /// Reconstructs the slot identity passed to a detached observer child.
    static func existing(
        processIdentity: AgentPIDProcessIdentity,
        slotIndex: Int,
        leaseID: String,
        observationID: String
    ) -> Self? {
        existing(
            processIdentity: processIdentity,
            slotIndex: slotIndex,
            leaseID: leaseID,
            observationID: observationID,
            rootDirectory: defaultRootDirectory
        )
    }

    /// Reconstructs a slot identity under an explicit root directory.
    static func existing(
        processIdentity: AgentPIDProcessIdentity,
        slotIndex: Int,
        leaseID: String,
        observationID: String,
        rootDirectory: URL
    ) -> Self? {
        guard (0 ..< maximumConcurrentObserversPerProcess).contains(slotIndex),
              UUID(uuidString: leaseID) != nil,
              let observationID = AgentAttentionOpaqueIdentifier(
                  rawValue: observationID
              )?.rawValue else {
            return nil
        }
        return Self(
            processIdentity: processIdentity,
            slotIndex: slotIndex,
            leaseID: leaseID.lowercased(),
            observationID: observationID,
            rootDirectory: rootDirectory.standardizedFileURL
        )
    }

    /// Arguments that transfer exact lease ownership to the observer child.
    var commandArguments: [String] {
        [
            "--observer-lease-slot", String(slotIndex),
            "--observer-lease-id", leaseID,
        ]
    }

    /// Whether this value still owns its exact on-disk slot.
    var isCurrent: Bool {
        guard let lockDescriptor = Self.acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return false
        }
        defer { Self.releaseRootLock(lockDescriptor) }
        guard let record = Self.readLeaseRecord(at: slotURL) else {
            return false
        }
        return record.leaseID == leaseID
            && record.observationID == observationID
    }

    /// Attaches the exact spawned child generation to this claimed slot.
    func activate(
        childProcessIdentity: AgentPIDProcessIdentity
    ) -> Bool {
        guard let lockDescriptor = Self.acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return false
        }
        defer { Self.releaseRootLock(lockDescriptor) }
        guard let record = Self.readLeaseRecord(at: slotURL),
              record.leaseID == leaseID,
              record.observationID == observationID else {
            return false
        }
        return Self.replaceLeaseFile(
            at: slotURL,
            contents: serializedRecord(
                childProcessIdentity: childProcessIdentity
            )
        )
    }

    /// Releases the slot only when its exact lease identity still matches.
    func release() {
        guard let lockDescriptor = Self.acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return
        }
        defer { Self.releaseRootLock(lockDescriptor) }
        guard let record = Self.readLeaseRecord(at: slotURL),
              record.leaseID == leaseID,
              record.observationID == observationID else {
            return
        }
        _ = unlink(slotURL.path)
        _ = rmdir(generationDirectoryURL.path)
    }

    /// Cancels the exact observation owned by one process generation.
    static func cancel(
        processIdentity: AgentPIDProcessIdentity,
        observationID: String
    ) {
        cancel(
            processIdentity: processIdentity,
            observationID: observationID,
            rootDirectory: defaultRootDirectory
        )
    }

    /// Cancels an exact observation under an explicit root directory.
    static func cancel(
        processIdentity: AgentPIDProcessIdentity,
        observationID: String,
        rootDirectory: URL
    ) {
        guard let observationID = AgentAttentionOpaqueIdentifier(
            rawValue: observationID
        )?.rawValue else {
            return
        }
        cancelMatchingLeases(
            processIdentity: processIdentity,
            rootDirectory: rootDirectory.standardizedFileURL
        ) { $0 == observationID }
    }

    /// Cancels every observer owned by one exact process generation.
    static func cancelAll(
        processIdentity: AgentPIDProcessIdentity
    ) {
        cancelMatchingLeases(
            processIdentity: processIdentity,
            rootDirectory: defaultRootDirectory
        ) { _ in true }
    }

    private static var defaultRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-cursor-approval-observers-\(getuid())",
                isDirectory: true
            )
            .standardizedFileURL
    }

    private var generationDirectoryURL: URL {
        Self.generationDirectoryURL(
            processIdentity: processIdentity,
            rootDirectory: rootDirectory
        )
    }

    private var slotURL: URL {
        generationDirectoryURL.appendingPathComponent(
            "slot-\(slotIndex)",
            isDirectory: false
        )
    }

    private func serializedRecord(
        childProcessIdentity: AgentPIDProcessIdentity?
    ) -> [UInt8] {
        var lines = [leaseID, observationID]
        if let childProcessIdentity {
            lines += [
                String(childProcessIdentity.pid),
                String(childProcessIdentity.startSeconds),
                String(childProcessIdentity.startMicroseconds),
            ]
        }
        return Array((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func generationDirectoryURL(
        processIdentity: AgentPIDProcessIdentity,
        rootDirectory: URL
    ) -> URL {
        rootDirectory.appendingPathComponent(
            "\(processIdentity.pid)-\(processIdentity.startSeconds)-\(processIdentity.startMicroseconds)",
            isDirectory: true
        )
    }

    private static func acquireRootLock(rootDirectory: URL) -> Int32? {
        do {
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            return nil
        }
        let lockURL = rootDirectory.appendingPathComponent(
            lockFileName,
            isDirectory: false
        )
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        // A POSIX file lock is required because independent hook CLI processes
        // cannot share an actor while claiming the same fixed slot table.
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func releaseRootLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private static func isStaleLeaseFile(at url: URL) -> Bool {
        var fileInfo = stat()
        guard lstat(url.path, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG else {
            return false
        }
        let modifiedAt = TimeInterval(fileInfo.st_mtimespec.tv_sec)
            + TimeInterval(fileInfo.st_mtimespec.tv_nsec) / 1_000_000_000
        return Date.now.timeIntervalSince1970 - modifiedAt >= staleLeaseAge
    }

    private static func createLeaseFile(
        at url: URL,
        contents: [UInt8]
    ) -> Bool {
        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let didWrite = writeAll(contents, to: descriptor)
        if !didWrite {
            _ = unlink(url.path)
        }
        return didWrite
    }

    private static func replaceLeaseFile(
        at url: URL,
        contents: [UInt8]
    ) -> Bool {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
                isDirectory: false
            )
        guard createLeaseFile(at: temporaryURL, contents: contents) else {
            return false
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            _ = unlink(temporaryURL.path)
            return false
        }
        return true
    }

    private static func writeAll(
        _ bytes: [UInt8],
        to descriptor: Int32
    ) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    private static func readLeaseRecord(
        at url: URL
    ) -> (
        leaseID: String,
        observationID: String,
        childProcessIdentity: AgentPIDProcessIdentity?
    )? {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG,
              fileInfo.st_size > 0,
              fileInfo.st_size <= off_t(maximumLeaseRecordBytes) else {
            return nil
        }
        var bytes = [UInt8](
            repeating: 0,
            count: Int(fileInfo.st_size)
        )
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            offset += count
        }
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        let lines = value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count >= 3,
              UUID(uuidString: lines[0]) != nil,
              let observationID = AgentAttentionOpaqueIdentifier(
                  rawValue: lines[1]
              )?.rawValue else {
            return nil
        }
        let childProcessIdentity: AgentPIDProcessIdentity?
        if lines.count >= 6,
           let pid = Int32(lines[2]),
           pid > 0,
           let startSeconds = Int64(lines[3]),
           let startMicroseconds = Int64(lines[4]) {
            childProcessIdentity = AgentPIDProcessIdentity(
                pid: pid,
                startSeconds: startSeconds,
                startMicroseconds: startMicroseconds
            )
        } else {
            childProcessIdentity = nil
        }
        return (
            leaseID: lines[0].lowercased(),
            observationID: observationID,
            childProcessIdentity: childProcessIdentity
        )
    }

    private static func cancelMatchingLeases(
        processIdentity: AgentPIDProcessIdentity,
        rootDirectory: URL,
        matches: (String) -> Bool
    ) {
        guard let lockDescriptor = acquireRootLock(
            rootDirectory: rootDirectory
        ) else {
            return
        }
        var childProcessIdentities: [AgentPIDProcessIdentity] = []
        let generationDirectory = generationDirectoryURL(
            processIdentity: processIdentity,
            rootDirectory: rootDirectory
        )
        for slotIndex in 0 ..< maximumConcurrentObserversPerProcess {
            let slotURL = generationDirectory.appendingPathComponent(
                "slot-\(slotIndex)",
                isDirectory: false
            )
            guard let record = readLeaseRecord(at: slotURL),
                  matches(record.observationID) else {
                continue
            }
            _ = unlink(slotURL.path)
            if let childProcessIdentity = record.childProcessIdentity {
                childProcessIdentities.append(childProcessIdentity)
            }
        }
        _ = rmdir(generationDirectory.path)
        releaseRootLock(lockDescriptor)

        for childProcessIdentity in childProcessIdentities
        where AgentPIDProcessIdentity(
            agentTurnPID: Int(childProcessIdentity.pid)
        ) == childProcessIdentity {
            _ = Darwin.kill(childProcessIdentity.pid, SIGTERM)
        }
    }
}
