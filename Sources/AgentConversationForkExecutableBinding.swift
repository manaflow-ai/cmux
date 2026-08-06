import Darwin
import Foundation

/// Binds the exact executable contents that passed explicit harness validation.
/// Writable installations use an adjacent user-immutable copy so scripts retain
/// relative assets. Sources the current user cannot replace run in place after
/// their file identity and content hash are revalidated.
struct AgentConversationForkExecutableBinding: Equatable, Hashable, Sendable {
    private struct AdjacentCopy: Equatable, Hashable, Sendable {
        let stagingPath: String
        let cleanupRecordPath: String
        let cleanupDirectoryPath: String
        let expectedCleanupDirectoryStatSignature: String
        let cleanupRecordContents: String
    }

    private enum Storage: Equatable, Hashable, Sendable {
        case adjacentCopy(AdjacentCopy)
        case protectedSource(expectedShellStatSignature: String)
    }

    private static let cleanupDirectoryName = "cmux-transfer-bindings"
    private static let cleanupRecordTTL: TimeInterval = 24 * 60 * 60

    let sourcePath: String
    let boundPath: String
    let expectedContentSHA256: String?
    private let storage: Storage

    init?(identity: AgentConversationForkExecutableIdentity) {
        let sourceURL = URL(fileURLWithPath: identity.realPath).standardizedFileURL
        let lookupURL = URL(fileURLWithPath: identity.lookupPath).standardizedFileURL
        let candidateDirectories = [
            sourceURL.deletingLastPathComponent(),
            lookupURL.deletingLastPathComponent(),
        ]
        var seenDirectories: Set<String> = []
        let adjacentDirectoryURL = candidateDirectories.first(where: { directoryURL in
            guard seenDirectories.insert(directoryURL.path).inserted else {
                return false
            }
            var status = stat()
            return stat(directoryURL.path, &status) == 0
                && status.st_mode & S_IFMT == S_IFDIR
                && UInt64(status.st_dev) == identity.device
                && Darwin.access(directoryURL.path, W_OK) == 0
        })

        sourcePath = sourceURL.path
        expectedContentSHA256 = identity.contentSHA256

        guard let directoryURL = adjacentDirectoryURL else {
            guard let expectedShellStatSignature = Self.protectedSourceStatSignature(
                identity: identity
            ) else {
                return nil
            }
            boundPath = sourceURL.path
            storage = .protectedSource(
                expectedShellStatSignature: expectedShellStatSignature
            )
            return
        }
        guard let cleanupDirectory = Self.prepareCleanupDirectory() else {
            return nil
        }

        let basename = sourceURL.lastPathComponent
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "."
                    || scalar == "_"
                    || scalar == "-"
                    ? Character(String(scalar))
                    : "_"
            }
        let safeBasename = String(basename.prefix(80))
        let token = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let filename = ".cmux-transfer-\(token)-\(safeBasename.isEmpty ? "agent" : safeBasename)"
        let generatedBoundPath = directoryURL
            .appendingPathComponent(filename, isDirectory: false)
            .path
        let generatedStagingPath = generatedBoundPath + ".source"
        let manifest: [String: Any] = [
            "version": 2,
            "boundPath": generatedBoundPath,
            "stagingPath": generatedStagingPath,
            "expectedContentSHA256": identity.contentSHA256 ?? "",
        ]
        guard let manifestData = try? JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ),
        let manifestString = String(data: manifestData, encoding: .utf8) else {
            return nil
        }

        boundPath = generatedBoundPath
        let cleanupRecordPath = cleanupDirectory.url
            .appendingPathComponent("\(token).json", isDirectory: false)
            .path
        storage = .adjacentCopy(AdjacentCopy(
            stagingPath: generatedStagingPath,
            cleanupRecordPath: cleanupRecordPath,
            cleanupDirectoryPath: cleanupDirectory.url.path,
            expectedCleanupDirectoryStatSignature: cleanupDirectory.statSignature,
            cleanupRecordContents: manifestString
        ))
    }

    /// Prepares the exact artifact used by the explicit version or help probe.
    /// The caller owns any adjacent-copy cleanup through ``removeArtifacts()``.
    func prepareValidatedArtifact(
        deadline: ContinuousClock.Instant? = nil
    ) -> Bool {
        guard expectedContentSHA256 != nil else { return false }
        switch storage {
        case .adjacentCopy(let copy):
            guard writeCleanupRecord(copy),
                  copySourceToBoundPath(deadline: deadline),
                  Darwin.chflags(boundPath, UInt32(UF_IMMUTABLE)) == 0,
                  boundArtifactIsValid(deadline: deadline) else {
                removeArtifacts()
                return false
            }
            return true
        case .protectedSource:
            return boundArtifactIsValid(deadline: deadline)
        }
    }

    func boundArtifactIsValid(
        deadline: ContinuousClock.Instant? = nil
    ) -> Bool {
        guard let expectedContentSHA256 else { return false }
        switch storage {
        case .adjacentCopy:
            return Self.immutableArtifact(
                atPath: boundPath,
                matchesSHA256: expectedContentSHA256,
                deadline: deadline
            )
        case .protectedSource(let expectedShellStatSignature):
            return Self.protectedSourceArtifact(
                atPath: sourcePath,
                expectedShellStatSignature: expectedShellStatSignature,
                expectedContentSHA256: expectedContentSHA256,
                deadline: deadline
            )
        }
    }

    func removeArtifacts() {
        guard case .adjacentCopy(let copy) = storage else { return }
        _ = Darwin.chflags(boundPath, 0)
        _ = Darwin.unlink(boundPath)
        _ = Darwin.unlink(copy.stagingPath)
        _ = Darwin.unlink(copy.cleanupRecordPath)
    }

    func shellCommand(running launchCommand: String) -> String {
        guard let expectedContentSHA256 else { return "exit 76" }
        let quotedSource = TerminalStartupShellQuoting.singleQuoted(sourcePath)
        let quotedExpectedHash = TerminalStartupShellQuoting.singleQuoted(
            expectedContentSHA256
        )
        if case .protectedSource(let expectedShellStatSignature) = storage {
            let quotedExpectedStat = TerminalStartupShellQuoting.singleQuoted(
                expectedShellStatSignature
            )
            return """
            cmux_transfer_source=\(quotedSource)
            cmux_transfer_source_actual=$(/usr/bin/stat -f '%d:%i:%p:%z:%m:%c' -- "$cmux_transfer_source") || exit 76
            if [[ "$cmux_transfer_source_actual" != \(quotedExpectedStat) ]]; then
              exit 76
            fi
            cmux_transfer_hash=$(/usr/bin/shasum -a 256 -- "$cmux_transfer_source") || exit 76
            cmux_transfer_hash=${cmux_transfer_hash%% *}
            if [[ "$cmux_transfer_hash" != \(quotedExpectedHash) ]]; then
              exit 76
            fi
            \(launchCommand)
            cmux_transfer_status=$?
            exit $cmux_transfer_status
            """
        }
        guard case .adjacentCopy(let copy) = storage else { return "exit 76" }
        let quotedBound = TerminalStartupShellQuoting.singleQuoted(boundPath)
        let quotedStaging = TerminalStartupShellQuoting.singleQuoted(copy.stagingPath)
        let quotedCleanupRecord = TerminalStartupShellQuoting.singleQuoted(
            copy.cleanupRecordPath
        )
        let quotedCleanupDirectory = TerminalStartupShellQuoting.singleQuoted(
            copy.cleanupDirectoryPath
        )
        let quotedExpectedCleanupDirectory = TerminalStartupShellQuoting.singleQuoted(
            copy.expectedCleanupDirectoryStatSignature
        )
        let quotedCleanupRecordContents = TerminalStartupShellQuoting.singleQuoted(
            copy.cleanupRecordContents
        )
        let quotedCleanup = TerminalStartupShellQuoting.singleQuoted(
            "/usr/bin/chflags nouchg \(quotedBound) 2>/dev/null || true; "
                + "/bin/rm -f -- \(quotedBound) \(quotedStaging) \(quotedCleanupRecord)"
        )
        return """
        cmux_transfer_source=\(quotedSource)
        cmux_transfer_bound=\(quotedBound)
        cmux_transfer_staging=\(quotedStaging)
        cmux_transfer_record=\(quotedCleanupRecord)
        cmux_transfer_record_directory=\(quotedCleanupDirectory)
        cmux_transfer_record_directory_actual=$(/usr/bin/stat -f '%d:%i:%p:%u' -- "$cmux_transfer_record_directory") || exit 76
        if [[ "$cmux_transfer_record_directory_actual" != \(quotedExpectedCleanupDirectory) ]]; then
          exit 76
        fi
        if ! (set -o noclobber; umask 077; /usr/bin/printf '%s' \(quotedCleanupRecordContents) > "$cmux_transfer_record"); then
          exit 76
        fi
        trap \(quotedCleanup) EXIT
        if ! /bin/ln -- "$cmux_transfer_source" "$cmux_transfer_staging"; then
          exit 76
        fi
        if [[ ! -f "$cmux_transfer_staging" || -L "$cmux_transfer_staging" ]]; then
          exit 76
        fi
        if ! (set -o noclobber; umask 077; /bin/cat -- "$cmux_transfer_staging" > "$cmux_transfer_bound"); then
          exit 76
        fi
        /bin/rm -f -- "$cmux_transfer_staging"
        /bin/chmod 500 "$cmux_transfer_bound" || exit 76
        /usr/bin/chflags uchg "$cmux_transfer_bound" || exit 76
        cmux_transfer_flags=$(/usr/bin/stat -f '%f' -- "$cmux_transfer_bound") || exit 76
        if (( (cmux_transfer_flags & 2) != 2 )); then
          exit 76
        fi
        cmux_transfer_hash=$(/usr/bin/shasum -a 256 -- "$cmux_transfer_bound") || exit 76
        cmux_transfer_hash=${cmux_transfer_hash%% *}
        if [[ "$cmux_transfer_hash" != \(quotedExpectedHash) ]]; then
          exit 76
        fi
        \(launchCommand)
        cmux_transfer_status=$?
        exit $cmux_transfer_status
        """
    }

    private func writeCleanupRecord(_ copy: AdjacentCopy) -> Bool {
        var directoryMetadata = stat()
        guard Darwin.lstat(copy.cleanupDirectoryPath, &directoryMetadata) == 0,
              Self.cleanupDirectoryStatSignature(directoryMetadata)
                == copy.expectedCleanupDirectoryStatSignature else {
            return false
        }
        let descriptor = Darwin.open(
            copy.cleanupRecordPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        let bytes = Array(copy.cleanupRecordContents.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
            }
            guard written > 0 else {
                _ = Darwin.unlink(copy.cleanupRecordPath)
                return false
            }
            offset += written
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.fsync(descriptor) == 0 else {
            _ = Darwin.unlink(copy.cleanupRecordPath)
            return false
        }
        return true
    }

    private func copySourceToBoundPath(
        deadline: ContinuousClock.Instant?
    ) -> Bool {
        let sourceDescriptor = Darwin.open(
            sourcePath,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(sourceDescriptor) }
        var sourceMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceMetadata) == 0,
              sourceMetadata.st_mode & S_IFMT == S_IFREG,
              sourceMetadata.st_size >= 0,
              sourceMetadata.st_size
                <= AgentConversationForkExecutableIdentity.maximumArtifactBytes,
              AgentConversationForkExecutableIdentity.workMayContinue(
                  deadline: deadline
              ) else {
            return false
        }
        let destinationDescriptor = Darwin.open(
            boundPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IXUSR
        )
        guard destinationDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(destinationDescriptor) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            guard AgentConversationForkExecutableIdentity.workMayContinue(
                deadline: deadline
            ) else { return false }
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead < 0, errno == EINTR { continue }
            guard bytesRead >= 0 else { return false }
            if bytesRead == 0 { break }
            var offset = 0
            while offset < bytesRead {
                let remaining = bytesRead - offset
                guard AgentConversationForkExecutableIdentity.workMayContinue(
                    deadline: deadline
                ) else { return false }
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        remaining
                    )
                }
                guard written > 0 else { return false }
                offset += written
            }
        }
        return Darwin.fchmod(destinationDescriptor, S_IRUSR | S_IXUSR) == 0
            && Darwin.fsync(destinationDescriptor) == 0
    }

    private static func protectedSourceStatSignature(
        identity: AgentConversationForkExecutableIdentity
    ) -> String? {
        var metadata = stat()
        guard Darwin.lstat(identity.realPath, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              fullStatSignature(metadata) == identity.shellStatSignature,
              sourceIsProtectedFromCurrentUser(
                  atPath: identity.realPath,
                  metadata: metadata
              ) else {
            return nil
        }
        return shellStatSignature(metadata)
    }

    private static func protectedSourceArtifact(
        atPath path: String,
        expectedShellStatSignature: String,
        expectedContentSHA256: String,
        deadline: ContinuousClock.Instant?
    ) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              shellStatSignature(metadata) == expectedShellStatSignature,
              sourceIsProtectedFromCurrentUser(atPath: path, metadata: metadata),
              AgentConversationForkExecutableIdentity.workMayContinue(
                  deadline: deadline
              ) else {
            return false
        }
        return AgentConversationForkExecutableIdentity.contentSHA256(
            atPath: path,
            deadline: deadline
        ) == expectedContentSHA256
    }

    private static func sourceIsProtectedFromCurrentUser(
        atPath path: String,
        metadata: stat
    ) -> Bool {
        var fileSystemMetadata = statfs()
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor >= 0 {
            defer { _ = Darwin.close(descriptor) }
            if Darwin.fstatfs(descriptor, &fileSystemMetadata) == 0,
               fileSystemMetadata.f_flags & UInt32(MNT_RDONLY) != 0 {
                return true
            }
        }

        let effectiveUserID = Darwin.geteuid()
        guard metadata.st_uid != effectiveUserID,
              Darwin.access(path, W_OK) != 0 else {
            return false
        }

        var directoryURL = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
        while true {
            var directoryMetadata = stat()
            guard Darwin.lstat(directoryURL.path, &directoryMetadata) == 0,
                  directoryMetadata.st_mode & S_IFMT == S_IFDIR,
                  directoryMetadata.st_uid != effectiveUserID,
                  Darwin.access(directoryURL.path, W_OK) != 0 else {
                return false
            }
            guard directoryURL.path != "/" else { return true }
            let parentURL = directoryURL.deletingLastPathComponent()
            guard parentURL.path != directoryURL.path else { return false }
            directoryURL = parentURL
        }
    }

    private static func fullStatSignature(_ metadata: stat) -> String {
        [
            String(UInt64(metadata.st_dev)),
            String(metadata.st_ino),
            String(metadata.st_mode, radix: 8),
            String(metadata.st_size),
            String(metadata.st_mtimespec.tv_sec),
            String(metadata.st_mtimespec.tv_nsec),
            String(metadata.st_ctimespec.tv_sec),
            String(metadata.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
    }

    private static func shellStatSignature(_ metadata: stat) -> String {
        [
            String(UInt64(metadata.st_dev)),
            String(metadata.st_ino),
            String(metadata.st_mode, radix: 8),
            String(metadata.st_size),
            String(metadata.st_mtimespec.tv_sec),
            String(metadata.st_ctimespec.tv_sec),
        ].joined(separator: ":")
    }

    private static func prepareCleanupDirectory(
        fileManager: FileManager = .default,
        currentDate: Date = .now
    ) -> (url: URL, statSignature: String)? {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(cleanupDirectoryName, isDirectory: true)
            .standardizedFileURL
        if Darwin.mkdir(directoryURL.path, S_IRWXU) != 0, errno != EEXIST {
            return nil
        }
        var metadata = stat()
        guard Darwin.lstat(directoryURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
              Darwin.access(directoryURL.path, W_OK | X_OK) == 0 else {
            return nil
        }
        pruneExpiredCleanupRecords(
            in: directoryURL,
            currentDate: currentDate,
            fileManager: fileManager
        )
        return (directoryURL, cleanupDirectoryStatSignature(metadata))
    }

    private static func pruneExpiredCleanupRecords(
        in directoryURL: URL,
        currentDate: Date,
        fileManager: FileManager
    ) {
        guard let recordURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }
        let cutoff = currentDate.addingTimeInterval(-cleanupRecordTTL)
        for recordURL in recordURLs {
            let name = recordURL.lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            let token = String(name.dropLast(5))
            guard token.count == 32,
                  token.unicodeScalars.allSatisfy({
                      (48...57).contains($0.value)
                          || (97...102).contains($0.value)
                  }) else {
                continue
            }
            var metadata = stat()
            guard Darwin.lstat(recordURL.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == Darwin.geteuid(),
                  metadata.st_nlink == 1,
                  metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
                  Date(
                      timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                  ) < cutoff else {
                continue
            }
            defer { _ = Darwin.unlink(recordURL.path) }
            guard let manifest = cleanupManifest(
                at: recordURL,
                expectedMetadata: metadata
            ),
            manifest.version == 2,
            URL(fileURLWithPath: manifest.boundPath).lastPathComponent
                .hasPrefix(".cmux-transfer-\(token)-"),
            manifest.stagingPath == manifest.boundPath + ".source" else {
                continue
            }
            _ = Darwin.unlink(manifest.stagingPath)
            guard immutableArtifact(
                atPath: manifest.boundPath,
                matchesSHA256: manifest.expectedContentSHA256
            ) else {
                continue
            }
            _ = Darwin.chflags(manifest.boundPath, 0)
            _ = Darwin.unlink(manifest.boundPath)
        }
    }

    private static func cleanupManifest(
        at recordURL: URL,
        expectedMetadata: stat
    ) -> (
        version: Int,
        boundPath: String,
        stagingPath: String,
        expectedContentSHA256: String
    )? {
        let descriptor = Darwin.open(
            recordURL.path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        var openedMetadata = stat()
        guard Darwin.fstat(descriptor, &openedMetadata) == 0,
              openedMetadata.st_dev == expectedMetadata.st_dev,
              openedMetadata.st_ino == expectedMetadata.st_ino,
              openedMetadata.st_size >= 0,
              openedMetadata.st_size <= 64 * 1_024 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: Int(openedMetadata.st_size))
        var offset = 0
        while offset < bytes.count {
            let remainingByteCount = bytes.count - offset
            let bytesRead = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    remainingByteCount
                )
            }
            guard bytesRead > 0 else { return nil }
            offset += bytesRead
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)),
              let manifest = object as? [String: Any],
              let version = manifest["version"] as? Int,
              let boundPath = manifest["boundPath"] as? String,
              boundPath.hasPrefix("/"),
              let stagingPath = manifest["stagingPath"] as? String,
              let expectedContentSHA256 = manifest["expectedContentSHA256"] as? String,
              expectedContentSHA256.count == 64 else {
            return nil
        }
        return (version, boundPath, stagingPath, expectedContentSHA256)
    }

    private static func immutableArtifact(
        atPath path: String,
        matchesSHA256 expectedContentSHA256: String,
        deadline: ContinuousClock.Instant? = nil
    ) -> Bool {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & (S_IRWXG | S_IRWXO | S_IWUSR) == 0,
              metadata.st_flags & UInt32(UF_IMMUTABLE) != 0 else {
            return false
        }
        return AgentConversationForkExecutableIdentity.contentSHA256(
            atPath: path,
            deadline: deadline
        )
            == expectedContentSHA256
    }

    private static func cleanupDirectoryStatSignature(_ metadata: stat) -> String {
        [
            String(UInt64(metadata.st_dev)),
            String(metadata.st_ino),
            String(metadata.st_mode, radix: 8),
            String(metadata.st_uid),
        ].joined(separator: ":")
    }
}
