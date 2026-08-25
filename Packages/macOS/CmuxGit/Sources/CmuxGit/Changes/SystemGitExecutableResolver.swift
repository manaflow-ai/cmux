import Foundation

/// Finds absolute Git executables that the app can use for bounded plumbing.
///
/// A repository may have been created by a newer Git installed by a package
/// manager while the system Git is older. The caller can try the returned
/// candidates in order and keep the first command that succeeds.
nonisolated struct SystemGitExecutableResolver: Sendable {
    private static let maximumCandidateCount = 8
    private static let wellKnownGitPaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/opt/local/bin/git",
        "/usr/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ]

    private let environment: [String: String]
    private let fileProbe: any GitExecutableFileProbing

    /// Creates a resolver using the supplied process environment.
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileProbe: (any GitExecutableFileProbing)? = nil
    ) {
        self.environment = environment
        self.fileProbe = fileProbe ?? SystemGitExecutableFileProbe()
    }

    /// Returns executable Git candidates, de-duplicated and bounded to known
    /// absolute paths from `PATH` plus standard macOS installation locations.
    func executableURLs() -> [URL] {
        // Prefer absolute, well-known installations so an ambient PATH entry
        // cannot shadow the system tool for ordinary repositories. PATH entries
        // remain fallback candidates for newer user-installed Git versions.
        var result: [URL] = []
        var seen: Set<String> = []
        for path in Self.wellKnownGitPaths {
            guard appendExecutable(atPath: path, to: &result, seen: &seen) else { continue }
            if result.count == Self.maximumCandidateCount { return result }
        }
        if let searchPath = environment["PATH"] {
            for entry in searchPath.split(separator: ":") {
                guard entry.first == "/" else { continue }
                let path = URL(fileURLWithPath: String(entry), isDirectory: true)
                    .appendingPathComponent("git", isDirectory: false)
                    .path
                guard appendExecutable(atPath: path, to: &result, seen: &seen) else { continue }
                if result.count == Self.maximumCandidateCount { return result }
            }
        }

        // Keep a deterministic spawn failure rather than silently switching to
        // a relative executable when a stripped-down environment has no Git.
        if result.isEmpty {
            result.append(URL(fileURLWithPath: "/usr/bin/git"))
        }
        return result
    }

    private func appendExecutable(
        atPath path: String,
        to result: inout [URL],
        seen: inout Set<String>
    ) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard seen.insert(standardizedPath).inserted else { return false }
        guard fileProbe.isExecutableFile(atPath: standardizedPath) else {
            return false
        }
        result.append(URL(fileURLWithPath: standardizedPath))
        return true
    }
}
