import Darwin
import Foundation

/// Normalizes existing executable search directories without carrying malformed PATH values.
public struct AgentExecutableSearchPathResolver: Sendable {
    private let currentDirectoryPath: String
    private let directoryExists: @Sendable (String) -> Bool

    /// Creates a search-path resolver rooted at the current process directory.
    ///
    /// - Parameters:
    ///   - currentDirectoryPath: The directory used to resolve relative PATH
    ///     entries. The process current directory is used by default.
    ///   - directoryExists: The filesystem probe used before normalization.
    ///     The default follows symlinks and accepts directories only.
    public init(
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        directoryExists: @escaping @Sendable (String) -> Bool = { path in
            var metadata = stat()
            return stat(path, &metadata) == 0
                && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        }
    ) {
        self.currentDirectoryPath = currentDirectoryPath
        self.directoryExists = directoryExists
    }

    /// Returns deduplicated, standardized directories from raw PATH components.
    ///
    /// Raw components are validated before trimming or URL normalization. This
    /// prevents control-byte values from becoming cwd-prefixed paths, and the
    /// pre-normalization directory probe prevents a missing component such as
    /// `missing-directory/..` from collapsing into the current directory.
    ///
    /// - Parameter rawDirectories: PATH components in lookup order.
    /// - Returns: Existing, absolute, standardized directories in first-seen order.
    public func normalizedDirectories(from rawDirectories: [String]) -> [String] {
        let currentDirectory = URL(
            fileURLWithPath: currentDirectoryPath,
            isDirectory: true
        )
        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(rawDirectories.count)

        for rawDirectory in rawDirectories {
            guard !rawDirectory.unicodeScalars.contains(where: Self.isMalformedScalar) else {
                continue
            }
            let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let candidate: String
            if trimmed.hasPrefix("/") {
                candidate = trimmed
            } else {
                candidate = currentDirectory
                    .appendingPathComponent(trimmed, isDirectory: true)
                    .path
            }
            guard directoryExists(candidate) else { continue }

            let standardized = URL(fileURLWithPath: candidate, isDirectory: true)
                .standardizedFileURL
                .path
            guard seen.insert(standardized).inserted else { continue }
            normalized.append(standardized)
        }
        return normalized
    }

    private static func isMalformedScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{FFFD}"
    }
}
