import Darwin
import Foundation

/// Produces an adjacent owner-only copy of the exact executable contents that
/// passed explicit harness validation. The copy is user-immutable before it is
/// probed or launched, while the adjacent path preserves script-relative assets.
struct AgentConversationForkExecutableBinding: Equatable, Hashable, Sendable {
    private static let cleanupDirectoryName = "cmux-transfer-bindings"
    private static let cleanupRecordTTL: TimeInterval = 24 * 60 * 60

    let sourcePath: String
    let boundPath: String
    let expectedContentSHA256: String?
    private let stagingPath: String
    private let cleanupRecordPath: String
    private let cleanupDirectoryPath: String
    private let expectedCleanupDirectoryStatSignature: String
    private let cleanupRecordContents: String

    init?(identity: AgentConversationForkExecutableIdentity) {
        let sourceURL = URL(fileURLWithPath: identity.realPath).standardizedFileURL
        let lookupURL = URL(fileURLWithPath: identity.lookupPath).standardizedFileURL
        let candidateDirectories = [
            sourceURL.deletingLastPathComponent(),
            lookupURL.deletingLastPathComponent(),
        ]
        var seenDirectories: Set<String> = []
        guard let directoryURL = candidateDirectories.first(where: { directoryURL in
            guard seenDirectories.insert(directoryURL.path).inserted else {
                return false
            }
            var status = stat()
            return stat(directoryURL.path, &status) == 0
                && status.st_mode & S_IFMT == S_IFDIR
                && UInt64(status.st_dev) == identity.device
                && Darwin.access(directoryURL.path, W_OK) == 0
        }),
        let cleanupDirectory = Self.prepareCleanupDirectory() else {
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

        sourcePath = sourceURL.path
        boundPath = generatedBoundPath
        expectedContentSHA256 = identity.contentSHA256
        stagingPath = generatedStagingPath
        cleanupRecordPath = cleanupDirectory.url
            .appendingPathComponent("\(token).json", isDirectory: false)
            .path
        cleanupDirectoryPath = cleanupDirectory.url.path
        expectedCleanupDirectoryStatSignature = cleanupDirectory.statSignature
        cleanupRecordContents = manifestString
    }

    /// Materializes the exact immutable artifact used by the explicit version
    /// or help probe. The caller owns cleanup through ``removeArtifacts()``.
    func materializeImmutableCopy() -> Bool {
        guard expectedContentSHA256 != nil,
              writeCleanupRecord(),
              copySourceToBoundPath(),
              Darwin.chflags(boundPath, UInt32(UF_IMMUTABLE)) == 0,
              boundArtifactIsValid() else {
            removeArtifacts()
            return false
        }
        return true
    }

    func boundArtifactIsValid() -> Bool {
        guard let expectedContentSHA256 else { return false }
        return Self.immutableArtifact(
            atPath: boundPath,
            matchesSHA256: expectedContentSHA256
        )
    }

    func removeArtifacts() {
        _ = Darwin.chflags(boundPath, 0)
        _ = Darwin.unlink(boundPath)
        _ = Darwin.unlink(stagingPath)
        _ = Darwin.unlink(cleanupRecordPath)
    }

    func shellCommand(running launchCommand: String) -> String {
        guard let expectedContentSHA256 else { return "exit 76" }
        let quotedSource = TerminalStartupShellQuoting.singleQuoted(sourcePath)
        let quotedBound = TerminalStartupShellQuoting.singleQuoted(boundPath)
        let quotedStaging = TerminalStartupShellQuoting.singleQuoted(stagingPath)
        let quotedExpectedHash = TerminalStartupShellQuoting.singleQuoted(
            expectedContentSHA256
        )
        let quotedCleanupRecord = TerminalStartupShellQuoting.singleQuoted(
            cleanupRecordPath
        )
        let quotedCleanupDirectory = TerminalStartupShellQuoting.singleQuoted(
            cleanupDirectoryPath
        )
        let quotedExpectedCleanupDirectory = TerminalStartupShellQuoting.singleQuoted(
            expectedCleanupDirectoryStatSignature
        )
        let quotedCleanupRecordContents = TerminalStartupShellQuoting.singleQuoted(
            cleanupRecordContents
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

    private func writeCleanupRecord() -> Bool {
        var directoryMetadata = stat()
        guard Darwin.lstat(cleanupDirectoryPath, &directoryMetadata) == 0,
              Self.cleanupDirectoryStatSignature(directoryMetadata)
                == expectedCleanupDirectoryStatSignature else {
            return false
        }
        let descriptor = Darwin.open(
            cleanupRecordPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        let bytes = Array(cleanupRecordContents.utf8)
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
                _ = Darwin.unlink(cleanupRecordPath)
                return false
            }
            offset += written
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.fsync(descriptor) == 0 else {
            _ = Darwin.unlink(cleanupRecordPath)
            return false
        }
        return true
    }

    private func copySourceToBoundPath() -> Bool {
        let sourceDescriptor = Darwin.open(
            sourcePath,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(sourceDescriptor) }
        var sourceMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceMetadata) == 0,
              sourceMetadata.st_mode & S_IFMT == S_IFREG else {
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
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            guard bytesRead >= 0 else { return false }
            if bytesRead == 0 { break }
            var offset = 0
            while offset < bytesRead {
                let remaining = bytesRead - offset
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
        matchesSHA256 expectedContentSHA256: String
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
        return AgentConversationForkExecutableIdentity.contentSHA256(atPath: path)
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
