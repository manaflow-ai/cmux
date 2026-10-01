public import Foundation

/// Owns the private remote directory and cleanup contract for pasted files.
public struct RemotePasteFileTransferPolicy: Equatable, Sendable {
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
        let suffix = sanitizedExtension(fileURL.pathExtension)
        let extensionSuffix = suffix.isEmpty ? "" : "." + suffix
        let fileName = "cmux-paste-" + uuid.uuidString.lowercased() + extensionSuffix
        return "~/" + relativeDirectoryPath + "/" + fileName
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
        ].joined(separator: "\n")
    }

    /// Returns a shell script that enforces mode `0600` after SCP creates a file.
    public func finalizeScript(for remotePath: String) -> String {
        let prefix = "~/" + relativeDirectoryPath + "/"
        guard remotePath.hasPrefix(prefix),
              let fileName = remotePath.split(separator: "/").last,
              fileName.hasPrefix("cmux-paste-") else {
            return "false"
        }
        let path = "\"$HOME/" + relativeDirectoryPath + "/" + String(fileName) + "\""
        return "chmod 600 -- \(path) && test -f \(path)"
    }

    /// Returns a shell script that removes only files owned by this policy.
    public func cleanupScript(for remotePaths: [String]) -> String {
        let prefix = "~/" + relativeDirectoryPath + "/"
        let fileNames = remotePaths.compactMap { remotePath -> String? in
            guard remotePath.hasPrefix(prefix),
                  let fileName = remotePath.split(separator: "/").last,
                  fileName.hasPrefix("cmux-paste-") else {
                return nil
            }
            return String(fileName)
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
