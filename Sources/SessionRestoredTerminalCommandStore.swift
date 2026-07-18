import Darwin
import Foundation
import os

/// Publishes short-lived shell launchers without trusting path-based temporary
/// directory operations. Every caller gets the same private-directory,
/// bounded-pruning, and atomic-publication invariants.
enum PrivateLauncherScriptStore {
    static let maximumDirectoryEntriesPerPass = 256

    private static let stagingNamePrefix = ".cmux-private-launcher-"
    private static let maximumScriptBytes = 1 * 1_024 * 1_024
    private static let inProcessDirectoryClaims = OSAllocatedUnfairLock(
        initialState: Set<DirectoryIdentity>()
    )

    private struct DirectoryIdentity: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(bitPattern: Int64(status.st_dev))
            inode = UInt64(status.st_ino)
        }
    }

    private enum PruneResult {
        case ready
        case overflow
        case failed
    }

    static func write(
        contents: String,
        directoryName: String,
        filenamePrefix: String,
        temporaryDirectory: URL,
        scriptTTL: TimeInterval
    ) -> URL? {
        guard isSafePathComponent(directoryName),
              let data = contents.data(using: .utf8),
              !data.isEmpty,
              data.count <= maximumScriptBytes else {
            return nil
        }

        let parentDescriptor = open(
            temporaryDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { return nil }
        defer { Darwin.close(parentDescriptor) }

        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              ownedDirectoryStatusIsSafe(parentStatus) else {
            return nil
        }

        var createdDirectory = false
        if mkdirat(parentDescriptor, directoryName, mode_t(S_IRWXU)) == 0 {
            createdDirectory = true
        } else if errno != EEXIST {
            return nil
        }

        let directoryDescriptor = openat(
            parentDescriptor,
            directoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { return nil }
        defer { Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              ownedDirectoryStatusIsSafe(directoryStatus),
              fchmod(directoryDescriptor, mode_t(S_IRWXU)) == 0,
              fstat(directoryDescriptor, &directoryStatus) == 0,
              ownedPrivateDirectoryStatusIsSafe(directoryStatus) else {
            return nil
        }
        if createdDirectory, fsync(parentDescriptor) != 0 { return nil }

        let directoryIdentity = DirectoryIdentity(directoryStatus)
        let claimedInProcess = inProcessDirectoryClaims.withLock { claims in
            claims.insert(directoryIdentity).inserted
        }
        guard claimedInProcess else { return nil }
        defer {
            _ = inProcessDirectoryClaims.withLock { claims in
                claims.remove(directoryIdentity)
            }
        }
        guard flock(directoryDescriptor, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { _ = flock(directoryDescriptor, LOCK_UN) }

        guard pruneExpiredScripts(
            directoryDescriptor: directoryDescriptor,
            cutoff: Date().addingTimeInterval(-scriptTTL)
        ) == .ready else {
            return nil
        }

        let safePrefix = sanitizedFilenamePrefix(filenamePrefix)
        let finalName = "\(safePrefix)-\(UUID().uuidString).zsh"
        let stagingName = "\(stagingNamePrefix)\(UUID().uuidString).tmp"
        let stagingDescriptor = openat(
            directoryDescriptor,
            stagingName,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard stagingDescriptor >= 0 else { return nil }
        var openStagingDescriptor = stagingDescriptor
        var stagingExists = true
        var removePublishedFile = false
        defer {
            if openStagingDescriptor >= 0 { Darwin.close(openStagingDescriptor) }
            var removedFile = false
            if stagingExists, unlinkat(directoryDescriptor, stagingName, 0) == 0 {
                removedFile = true
            }
            if removePublishedFile, unlinkat(directoryDescriptor, finalName, 0) == 0 {
                removedFile = true
            }
            if removedFile { _ = fsync(directoryDescriptor) }
        }

        var stagingStatus = stat()
        guard fstat(stagingDescriptor, &stagingStatus) == 0,
              ownedSingleLinkRegularFileStatusIsSafe(stagingStatus),
              fchmod(stagingDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              writeAll(data, to: stagingDescriptor),
              fsync(stagingDescriptor) == 0 else {
            return nil
        }
        guard Darwin.close(stagingDescriptor) == 0 else {
            openStagingDescriptor = -1
            return nil
        }
        openStagingDescriptor = -1

        guard renameatx_np(
            directoryDescriptor,
            stagingName,
            directoryDescriptor,
            finalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            return nil
        }
        stagingExists = false
        removePublishedFile = true
        guard fsync(directoryDescriptor) == 0 else { return nil }

        var finalStatus = stat()
        guard fstatat(
            directoryDescriptor,
            finalName,
            &finalStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            ownedSingleLinkRegularFileStatusIsSafe(finalStatus),
            finalStatus.st_dev == stagingStatus.st_dev,
            finalStatus.st_ino == stagingStatus.st_ino,
            finalStatus.st_size == off_t(data.count),
            finalStatus.st_mode & mode_t(0o777) == mode_t(0o600),
            directoryPathStillMatches(
                parentDescriptor: parentDescriptor,
                directoryName: directoryName,
                expected: directoryStatus
            ),
            pathStillMatchesDescriptor(
                temporaryDirectory.path,
                expected: parentStatus
            ) else {
            return nil
        }

        removePublishedFile = false
        return temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(finalName, isDirectory: false)
    }

    private static func pruneExpiredScripts(
        directoryDescriptor: Int32,
        cutoff: Date
    ) -> PruneResult {
        let streamDescriptor = dup(directoryDescriptor)
        guard streamDescriptor >= 0 else { return .failed }
        _ = fcntl(streamDescriptor, F_SETFD, FD_CLOEXEC)
        guard let stream = fdopendir(streamDescriptor) else {
            Darwin.close(streamDescriptor)
            return .failed
        }
        defer { closedir(stream) }

        var examinedEntries = 0
        var removedAny = false
        while examinedEntries < maximumDirectoryEntriesPerPass {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { return .failed }
                if removedAny, fsync(directoryDescriptor) != 0 { return .failed }
                return .ready
            }
            let name = directoryEntryName(entry)
            guard name != ".", name != ".." else { continue }
            examinedEntries += 1
            guard shouldPrune(name: name) else { continue }

            var status = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                ownedSingleLinkRegularFileStatusIsSafe(status),
                modificationDate(status) < cutoff,
                unlinkat(directoryDescriptor, name, 0) == 0 else {
                continue
            }
            removedAny = true
        }

        if removedAny, fsync(directoryDescriptor) != 0 { return .failed }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                return errno == 0 ? .ready : .failed
            }
            let name = directoryEntryName(entry)
            if name != ".", name != ".." { return .overflow }
        }
    }

    private static func shouldPrune(name: String) -> Bool {
        (!name.hasPrefix(".") && name.hasSuffix(".zsh")) ||
            (name.hasPrefix(stagingNamePrefix) && name.hasSuffix(".tmp"))
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: Int(entry.pointee.d_namlen) + 1
            ) { String(cString: $0) }
        }
    }

    private static func modificationDate(_ status: stat) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec) +
                TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func directoryPathStillMatches(
        parentDescriptor: Int32,
        directoryName: String,
        expected: stat
    ) -> Bool {
        var current = stat()
        return fstatat(
            parentDescriptor,
            directoryName,
            &current,
            AT_SYMLINK_NOFOLLOW
        ) == 0 && sameFileIdentity(current, expected: expected) &&
            ownedPrivateDirectoryStatusIsSafe(current)
    }

    private static func pathStillMatchesDescriptor(_ path: String, expected: stat) -> Bool {
        var current = stat()
        return lstat(path, &current) == 0 &&
            sameFileIdentity(current, expected: expected) &&
            ownedDirectoryStatusIsSafe(current)
    }

    private static func sameFileIdentity(_ status: stat, expected: stat) -> Bool {
        status.st_dev == expected.st_dev && status.st_ino == expected.st_ino
    }

    private static func ownedDirectoryStatusIsSafe(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR &&
            status.st_uid == geteuid() &&
            status.st_nlink > 0
    }

    private static func ownedPrivateDirectoryStatusIsSafe(_ status: stat) -> Bool {
        ownedDirectoryStatusIsSafe(status) &&
            status.st_mode & mode_t(0o777) == mode_t(0o700)
    }

    private static func ownedSingleLinkRegularFileStatusIsSafe(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG &&
            status.st_uid == geteuid() &&
            status.st_nlink == 1 &&
            status.st_size >= 0
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\0")
    }

    private static func sanitizedFilenamePrefix(_ rawValue: String) -> String {
        let bytes = rawValue.utf8.prefix(48)
        let sanitized = bytes.map { byte -> Character in
            switch byte {
            case 48...57, 65...90, 97...122:
                Character(UnicodeScalar(byte))
            case 45, 95:
                Character(UnicodeScalar(byte))
            default:
                "_"
            }
        }
        return sanitized.isEmpty ? "launcher" : String(sanitized)
    }
}

enum SessionRestoredTerminalCommandStore {
    private static let directoryName = "cmux-session-terminal-command"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        command: String,
        workingDirectory: String?,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }
        var lines = [
            "#!/bin/zsh",
            "rm -f -- \"$0\" 2>/dev/null || true"
        ]
        if let workingDirectory = normalized(workingDirectory) {
            let quotedDirectory = shellSingleQuoted(workingDirectory)
            lines.append("{ cd -- \(quotedDirectory) 2>/dev/null || [ ! -d \(quotedDirectory) ]; } || exit $?")
        }
        lines.append("exec \"${SHELL:-/bin/zsh}\" -lc \(shellSingleQuoted(trimmedCommand))")
        _ = fileManager
        return PrivateLauncherScriptStore.write(
            contents: lines.joined(separator: "\n") + "\n",
            directoryName: directoryName,
            filenamePrefix: "session-terminal",
            temporaryDirectory: temporaryDirectory,
            scriptTTL: scriptTTL
        )
    }

    static func launcherCommand(for scriptURL: URL) -> String {
        "/bin/zsh \(shellSingleQuoted(scriptURL.path))"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
