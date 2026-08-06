import Darwin
import Foundation

/// Creates the validated executable's hard link only inside the destination
/// terminal, immediately before launch. The random adjacent path preserves a
/// script launcher's relative resource directory while preventing later
/// replacement of its canonical pathname from changing the launched inode.
struct AgentConversationForkExecutableBinding: Equatable, Hashable, Sendable {
    private static let cleanupDirectoryName = "cmux-transfer-bindings"
    private static let cleanupRecordTTL: TimeInterval = 24 * 60 * 60

    let sourcePath: String
    let boundPath: String
    let expectedStatSignature: String
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
        }) else {
            return nil
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
        let manifest: [String: Any] = [
            "version": 1,
            "boundPath": generatedBoundPath,
            "expectedStatSignature": identity.shellStatSignature,
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
        expectedStatSignature = identity.shellStatSignature
        cleanupRecordPath = cleanupDirectory.url
            .appendingPathComponent("\(token).json", isDirectory: false)
            .path
        cleanupDirectoryPath = cleanupDirectory.url.path
        expectedCleanupDirectoryStatSignature = cleanupDirectory.statSignature
        cleanupRecordContents = manifestString
    }

    func shellCommand(running launchCommand: String) -> String {
        let quotedSource = TerminalStartupShellQuoting.singleQuoted(sourcePath)
        let quotedBound = TerminalStartupShellQuoting.singleQuoted(boundPath)
        let quotedExpected = TerminalStartupShellQuoting.singleQuoted(
            expectedStatSignature
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
            "/bin/rm -f -- \(quotedBound) \(quotedCleanupRecord)"
        )
        return """
        cmux_transfer_source=\(quotedSource)
        cmux_transfer_bound=\(quotedBound)
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
        if ! /bin/ln -- "$cmux_transfer_source" "$cmux_transfer_bound"; then
          exit 76
        fi
        cmux_transfer_actual=$(/usr/bin/stat -f '%d:%i:%p:%z:%m' -- "$cmux_transfer_bound") || {
          /bin/rm -f -- "$cmux_transfer_bound"
          exit 76
        }
        if [[ "$cmux_transfer_actual" != \(quotedExpected) ]]; then
          /bin/rm -f -- "$cmux_transfer_bound"
          exit 76
        fi
        \(launchCommand)
        cmux_transfer_status=$?
        exit $cmux_transfer_status
        """
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
        return (
            directoryURL,
            [
                String(UInt64(metadata.st_dev)),
                String(metadata.st_ino),
                String(metadata.st_mode, radix: 8),
                String(metadata.st_uid),
            ].joined(separator: ":")
        )
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
            manifest.version == 1,
            URL(fileURLWithPath: manifest.boundPath).lastPathComponent
                .hasPrefix(".cmux-transfer-\(token)-") else {
                continue
            }
            var boundMetadata = stat()
            guard Darwin.lstat(manifest.boundPath, &boundMetadata) == 0,
                  boundMetadata.st_mode & S_IFMT == S_IFREG,
                  statSignature(boundMetadata) == manifest.expectedStatSignature else {
                continue
            }
            _ = Darwin.unlink(manifest.boundPath)
        }
    }

    private static func cleanupManifest(
        at recordURL: URL,
        expectedMetadata: stat
    ) -> (version: Int, boundPath: String, expectedStatSignature: String)? {
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
              let expectedStatSignature = manifest["expectedStatSignature"] as? String else {
            return nil
        }
        return (version, boundPath, expectedStatSignature)
    }

    private static func statSignature(_ metadata: stat) -> String {
        [
            String(UInt64(metadata.st_dev)),
            String(metadata.st_ino),
            String(metadata.st_mode, radix: 8),
            String(metadata.st_size),
            String(metadata.st_mtimespec.tv_sec),
        ].joined(separator: ":")
    }
}
