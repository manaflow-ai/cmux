public import Foundation

/// Owns the private remote directory and cleanup contract for pasted files.
public struct RemotePasteFileTransferPolicy: Equatable, Sendable {
    private static let remoteHomeMarker = "__CMUX_REMOTE_PASTE_HOME__"

    /// The maximum number of bytes retained in one session's paste directory.
    public let maximumByteCount: Int64

    /// The age after which an uploaded paste file is eligible for cleanup.
    public let maximumAge: TimeInterval

    /// The random directory identity for one remote session.
    public let sessionID: UUID

    /// Creates a policy for one remote session.
    public init(
        sessionID: UUID = UUID(),
        maximumByteCount: Int64 = 200 * 1024 * 1024,
        maximumAge: TimeInterval = 24 * 60 * 60
    ) {
        self.sessionID = sessionID
        self.maximumByteCount = max(1, maximumByteCount)
        self.maximumAge = max(60, maximumAge)
    }

    /// Returns the shell path used by SCP for an uploaded file.
    public func remotePath(for fileURL: URL, uuid: UUID = UUID()) -> String {
        "~/" + relativePath(for: fileURL, uuid: uuid)
    }

    /// Returns an absolute remote path for an uploaded file.
    ///
    /// - Parameters:
    ///   - fileURL: The local file whose extension should be preserved.
    ///   - homeDirectory: The absolute home directory reported by the remote
    ///     maintenance script.
    ///   - uuid: The file identity used in the generated name.
    /// - Returns: An absolute path below this policy's private session directory.
    public func remotePath(
        for fileURL: URL,
        homeDirectory: String,
        uuid: UUID = UUID()
    ) -> String {
        let normalizedHome = homeDirectory.hasSuffix("/") && homeDirectory != "/"
            ? String(homeDirectory.dropLast())
            : homeDirectory
        let relativePath = relativePath(for: fileURL, uuid: uuid)
        return normalizedHome == "/" ? "/" + relativePath : normalizedHome + "/" + relativePath
    }

    /// Extracts the absolute home directory emitted by ``maintenanceScript()``.
    ///
    /// Remote login startup files may write unrelated lines to standard output,
    /// so the parser only accepts the tagged line and ignores all other output.
    ///
    /// - Parameter output: Standard output captured from the maintenance SSH command.
    /// - Returns: An absolute home directory, or `nil` when the marker is absent
    ///   or malformed.
    public func remoteHomeDirectory(fromMaintenanceOutput output: String) -> String? {
        let prefix = Self.remoteHomeMarker
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard line.hasPrefix(prefix) else { continue }
            let home = String(line.dropFirst(prefix.count))
            guard home.hasPrefix("/"),
                  !home.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                continue
            }
            return home
        }
        return nil
    }

    /// Returns the relative path below this policy's private session directory.
    private func relativePath(for fileURL: URL, uuid: UUID) -> String {
        let suffix = sanitizedExtension(fileURL.pathExtension)
        let extensionSuffix = suffix.isEmpty ? "" : "." + suffix
        let fileName = "cmux-paste-" + uuid.uuidString.lowercased() + extensionSuffix
        return relativeDirectoryPath + "/" + fileName
    }

    /// Returns a shell script that creates the private directory and removes stale or oversized files.
    public func maintenanceScript() -> String {
        let directory = shellDirectoryExpression
        let ageMinutes = max(1, Int(maximumAge / 60))
        return [
            "set -eu",
            "dir=" + directory,
            "umask 077",
            "mkdir -p \"$dir\"",
            "chmod 700 \"$dir\"",
            "find \"$dir\" -type f -name 'cmux-paste-*' -mmin +" + String(ageMinutes) + " -delete",
            "total=0",
            "for file in \"$dir\"/cmux-paste-*; do",
            "  [ -f \"$file\" ] || continue",
            "  bytes=$(wc -c < \"$file\" 2>/dev/null || printf '0')",
            "  total=$((total + bytes))",
            "done",
            "while [ \"$total\" -gt " + String(maximumByteCount) + " ]; do",
            "  oldest=''",
            "  oldest_mtime=9223372036854775807",
            "  for file in \"$dir\"/cmux-paste-*; do",
            "    [ -f \"$file\" ] || continue",
            "    mtime=$(stat -c %Y \"$file\" 2>/dev/null || stat -f %m \"$file\" 2>/dev/null || printf '0')",
            "    if [ \"$mtime\" -lt \"$oldest_mtime\" ]; then",
            "      oldest=\"$file\"",
            "      oldest_mtime=\"$mtime\"",
            "    fi",
            "  done",
            "  [ -n \"$oldest\" ] || break",
            "  bytes=$(wc -c < \"$oldest\" 2>/dev/null || printf '0')",
            "  rm -f -- \"$oldest\"",
            "  total=$((total - bytes))",
            "done",
            "printf '\(Self.remoteHomeMarker)%s\\n' \"$HOME\"",
        ].joined(separator: "\n")
    }

    /// Returns a shell script that enforces mode `0600` after SCP creates a file.
    public func finalizeScript(for remotePath: String) -> String {
        guard let fileName = ownedFileName(from: remotePath) else {
            return "false"
        }
        let path = "\"$HOME/" + relativeDirectoryPath + "/" + String(fileName) + "\""
        return "chmod 600 -- \(path) && test -f \(path)"
    }

    /// Returns a shell script that removes only files owned by this policy.
    public func cleanupScript(for remotePaths: [String]) -> String {
        let fileNames = remotePaths.compactMap { remotePath -> String? in
            ownedFileName(from: remotePath).map(String.init)
        }
        guard fileNames.count == remotePaths.count, !fileNames.isEmpty else {
            return "true"
        }
        let paths = fileNames.map {
            "\"$HOME/" + relativeDirectoryPath + "/" + $0 + "\""
        }.joined(separator: " ")
        return "rm -f -- " + paths
    }

    /// Returns a shell script that removes this session's paste files after relay teardown.
    public func teardownCleanupScript() -> String {
        let directory = shellDirectoryExpression
        return [
            "set -eu",
            "dir=" + directory,
            "if [ -d \"$dir\" ]; then",
            "  find \"$dir\" -type f -name 'cmux-paste-*' -delete",
            "  rmdir \"$dir\" 2>/dev/null || true",
            "fi",
        ].joined(separator: "\n")
    }

    private var relativeDirectoryPath: String {
        ".cache/cmux/paste/" + sessionID.uuidString.lowercased()
    }

    private var shellDirectoryExpression: String {
        "\"$HOME/" + relativeDirectoryPath + "\""
    }

    private func ownedFileName(from remotePath: String) -> Substring? {
        let directorySuffix = "/" + relativeDirectoryPath + "/"
        guard remotePath.hasPrefix("/") || remotePath.hasPrefix("~/"),
              let range = remotePath.range(of: directorySuffix, options: .backwards) else {
            return nil
        }
        let fileName = remotePath[range.upperBound...]
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              fileName.hasPrefix("cmux-paste-") else {
            return nil
        }
        return fileName
    }

    private func sanitizedExtension(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.prefix(16)
        var result = ""
        for scalar in scalars where
            (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 97 && scalar.value <= 122) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
