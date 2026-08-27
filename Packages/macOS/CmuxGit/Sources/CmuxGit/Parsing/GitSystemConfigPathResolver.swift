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
                for candidatePath in [executable.path, executable.resolvingSymlinksInPath().path] {
                    if let configURL = systemConfigURL(forExecutablePath: candidatePath) {
                        return configURL
                    }
                }
                break
            }
        }
        return URL(fileURLWithPath: "/etc/gitconfig")
    }

    private func systemConfigURL(forExecutablePath path: String) -> URL? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if isAppleToolchainGit(normalized) {
            return URL(fileURLWithPath: "/etc/gitconfig")
        }
        guard let prefix = installationPrefix(from: normalized) else {
            return nil
        }
        return URL(fileURLWithPath: prefix)
            .appendingPathComponent("etc/gitconfig")
            .standardizedFileURL
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
}
