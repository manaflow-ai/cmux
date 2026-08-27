import Foundation

/// Finds absolute Git executables that the app can use for bounded plumbing.
///
/// A repository may have been created by a newer Git installed by a package
/// manager while the system Git is older. The caller can try the returned
/// candidates in order and keep the first command that succeeds.
nonisolated struct SystemGitExecutableResolver: Sendable {
    private static let maximumCandidateCount = 8
    /// Keeps PATH discovery bounded while leaving room for both system fallbacks.
    private static let maximumReferenceCandidateCount = 32
    private static let preferredGitPaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/opt/local/bin/git",
    ]
    private static let systemGitPaths = [
        "/usr/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
    ]
    private static let wellKnownGitPaths = [
        "/usr/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/opt/local/bin/git",
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
                guard appendCandidate(atPath: path, to: &result, seen: &seen) else { continue }
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

    /// Returns a small candidate set for a non-files reference probe.
    ///
    /// User-installed PATH shims are included before the older system tools so
    /// a compatible Git is reachable without making ordinary commands trust
    /// PATH or spawning every installation.
    func referenceExecutableURLs() -> [URL] {
        var result: [URL] = []
        var seen: Set<String> = []
        let maximumUserCandidateCount = max(0, Self.maximumReferenceCandidateCount - Self.systemGitPaths.count)
        // Leave one slot for absolute PATH candidates whenever they exist;
        // package-manager installs and version-manager shims are both common.
        let preferredCandidateLimit = max(0, maximumUserCandidateCount - 1)
        for path in Self.preferredGitPaths where result.count < preferredCandidateLimit {
            guard appendExecutable(atPath: path, to: &result, seen: &seen) else { continue }
        }
        if let searchPath = environment["PATH"] {
            let entries = searchPath.split(separator: ":")
            let pathCandidateLimit = maximumUserCandidateCount - result.count
            let headCount = pathCandidateLimit / 2
            let selectedEntries = Array(entries.prefix(headCount))
                + Array(entries.suffix(pathCandidateLimit - headCount))
            for entry in selectedEntries {
                guard entry.first == "/" else { continue }
                let path = URL(fileURLWithPath: String(entry), isDirectory: true)
                    .appendingPathComponent("git", isDirectory: false)
                    .path
                // Reference probing deliberately honors absolute user PATH
                // entries (asdf/mise shims, Nix, ~/.local/bin, or an Xcode
                // bundle). The candidate count keeps this bounded; these
                // candidates are validated when a bounded command is spawned.
                guard !Self.systemGitPaths.contains(path) else { continue }
                guard result.count < maximumUserCandidateCount,
                      appendCandidate(atPath: path, to: &result, seen: &seen) else { continue }
                if result.count == maximumUserCandidateCount {
                    break
                }
            }
        }
        // If PATH had no usable entry, fill the remaining user slot with the
        // next known installation before appending system fallbacks.
        for path in Self.preferredGitPaths where result.count < maximumUserCandidateCount {
            guard appendExecutable(atPath: path, to: &result, seen: &seen) else { continue }
        }
        for path in Self.systemGitPaths {
            guard appendExecutable(atPath: path, to: &result, seen: &seen) else { continue }
            if result.count == Self.maximumReferenceCandidateCount { break }
        }
        if result.isEmpty {
            result.append(URL(fileURLWithPath: "/usr/bin/git"))
        }
        return Array(result.prefix(Self.maximumReferenceCandidateCount))
    }

    /// Adds an absolute candidate without touching the filesystem. PATH entries
    /// are validated when the bounded Git process is spawned, keeping resolver
    /// construction safe even when PATH names an unavailable mount.
    private func appendCandidate(
        atPath path: String,
        to result: inout [URL],
        seen: inout Set<String>
    ) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard seen.insert(standardizedPath).inserted else { return false }
        result.append(URL(fileURLWithPath: standardizedPath))
        return true
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
