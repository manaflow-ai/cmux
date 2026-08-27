import Foundation

/// Resolves Git's system config without mistaking Apple toolchain shims for
/// a standalone installation prefix.
struct GitSystemConfigPathResolver {
    private let fileManager: FileManager

    /// Creates a resolver with an injectable filesystem provider.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the automatic system config path for an environment.
    func automaticSystemConfigURL(environment: [String: String]) -> URL {
        if let path = environment["PATH"] {
            for component in path.split(separator: ":", omittingEmptySubsequences: true) {
                let executable = URL(fileURLWithPath: String(component))
                    .appendingPathComponent("git")
                guard fileManager.isExecutableFile(atPath: executable.path) else {
                    continue
                }
                let resolvedPath = executable.resolvingSymlinksInPath().path
                if let configURL = systemConfigURL(
                    executablePath: executable.path,
                    resolvedExecutablePath: resolvedPath
                ) {
                    return configURL
                }
                break
            }
        }
        return URL(fileURLWithPath: "/etc/gitconfig")
    }

    private func systemConfigURL(
        executablePath: String,
        resolvedExecutablePath: String
    ) -> URL? {
        let normalizedExecutablePath = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .path
        let normalizedResolvedPath = URL(fileURLWithPath: resolvedExecutablePath)
            .standardizedFileURL
            .path
        if isAppleToolchainGit(normalizedResolvedPath)
            || isAppleToolchainGit(normalizedExecutablePath) {
            return URL(fileURLWithPath: "/etc/gitconfig")
        }
        if let homebrewPrefix = homebrewInstallationPrefix(from: normalizedResolvedPath) {
            return URL(fileURLWithPath: homebrewPrefix)
                .appendingPathComponent("etc/gitconfig")
                .standardizedFileURL
        }
        if let prefix = installationPrefix(from: normalizedResolvedPath)
            ?? installationPrefix(from: normalizedExecutablePath) {
            return URL(fileURLWithPath: prefix)
                .appendingPathComponent("etc/gitconfig")
                .standardizedFileURL
        }
        return nil
    }

    private func isAppleToolchainGit(_ path: String) -> Bool {
        path == "/usr/bin/git"
            || path == "/Library/Developer/CommandLineTools/usr/bin/git"
            || path.contains("/Contents/Developer/usr/bin/git")
    }

    private func installationPrefix(from path: String) -> String? {
        for suffix in ["/libexec/git-core", "/git-core"] {
            guard path.hasSuffix(suffix) else { continue }
            let prefix = String(path.dropLast(suffix.count))
            return prefix.isEmpty ? "/" : prefix
        }

        let executableURL = URL(fileURLWithPath: path)
        guard executableURL.lastPathComponent == "git",
              executableURL.deletingLastPathComponent().lastPathComponent == "bin" else {
            return nil
        }
        return executableURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    private func homebrewInstallationPrefix(from path: String) -> String? {
        guard let range = path.range(of: "/Cellar/git/") else {
            return nil
        }
        let prefix = String(path[..<range.lowerBound])
        return prefix.isEmpty ? "/" : prefix
    }
}
