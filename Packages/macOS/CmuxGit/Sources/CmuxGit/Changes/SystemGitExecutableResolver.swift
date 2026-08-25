import Foundation

/// Finds absolute Git executables that the app can use for bounded plumbing.
///
/// A repository may have been created by a newer Git installed by a package
/// manager while the system Git is older. The caller can try the returned
/// candidates in order and keep the first command that succeeds.
nonisolated struct SystemGitExecutableResolver: Sendable {
    private static let wellKnownGitPaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/opt/local/bin/git",
        "/usr/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ]

    private let environment: [String: String]

    /// Creates a resolver using the supplied process environment.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// Returns executable Git candidates, de-duplicated and bounded to known
    /// absolute paths from `PATH` plus standard macOS installation locations.
    func executableURLs() -> [URL] {
        // Prefer absolute, well-known installations so an ambient PATH entry
        // cannot shadow the system tool for ordinary repositories. PATH entries
        // remain fallback candidates for newer user-installed Git versions.
        var paths = Self.wellKnownGitPaths
        if let searchPath = environment["PATH"] {
            paths.append(contentsOf: searchPath.split(separator: ":").compactMap { entry in
                guard entry.first == "/" else { return nil }
                return URL(fileURLWithPath: String(entry), isDirectory: true)
                    .appendingPathComponent("git", isDirectory: false)
                    .path
            })
        }
        var result: [URL] = []
        var seen: Set<String> = []
        for path in paths {
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(standardizedPath).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: standardizedPath,
                isDirectory: &isDirectory
            ),
            !isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: standardizedPath) else {
                continue
            }
            result.append(URL(fileURLWithPath: standardizedPath))
        }

        // Keep a deterministic spawn failure rather than silently switching to
        // a relative executable when a stripped-down environment has no Git.
        if result.isEmpty {
            result.append(URL(fileURLWithPath: "/usr/bin/git"))
        }
        return result
    }
}
