import Foundation

/// Locates a local `cmuxd-remote` binary to back the agent chat surface.
///
/// Resolution order mirrors the remote-bootstrap conventions:
/// 1. `CMUX_REMOTE_DAEMON_BINARY`, honored only when
///    `CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1` is also set (the same explicit
///    opt-in gate the `cmux ssh` path uses for dev binaries).
/// 2. The checksum-verified `remote-daemons` cache the SSH bootstrap fills:
///    `<state>/remote-daemons/<version>/<goos>-<goarch>/cmuxd-remote`, current
///    app version first, then the newest other cached version (the `agent.*`
///    protocol is additive, so a newer cached daemon is preferable to none).
///
/// No network: when nothing is cached the feature reports the daemon as
/// unavailable instead of downloading.
struct AgentDaemonBinaryLocator {
    /// The locator outcome: a runnable binary or a human-readable reason.
    enum Outcome {
        case found(URL)
        case unavailable(detail: String)
    }

    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func locate() -> Outcome {
        if let override = explicitOverrideURL() {
            if isExecutableFile(override) {
                return .found(override)
            }
            return .unavailable(detail: "CMUX_REMOTE_DAEMON_BINARY points to a missing or non-executable file: \(override.path)")
        }
        let (goOS, goArch) = hostPlatform()
        let version = appVersionString()
        if let exact = try? Workspace.remoteDaemonCachedBinaryURL(
            version: version, goOS: goOS, goArch: goArch, fileManager: fileManager
        ), isExecutableFile(exact) {
            return .found(exact)
        }
        if let fallback = newestCachedBinary(goOS: goOS, goArch: goArch, excludingVersion: version) {
            return .found(fallback)
        }
        return .unavailable(
            detail: "No cached cmuxd-remote binary for \(goOS)-\(goArch); connect a remote host once (cmux ssh) or set CMUX_REMOTE_DAEMON_BINARY with CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1."
        )
    }

    private func explicitOverrideURL() -> URL? {
        guard environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1" else { return nil }
        guard let path = environment["CMUX_REMOTE_DAEMON_BINARY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    /// Scans the cache root for the newest other version holding a runnable
    /// binary for this platform. Versions sort newest-first lexicographically
    /// descending, which is correct for dotted versions of equal arity and an
    /// acceptable tiebreak otherwise.
    private func newestCachedBinary(goOS: String, goArch: String, excludingVersion: String) -> URL? {
        guard let anyVersion = try? Workspace.remoteDaemonCachedBinaryURL(
            version: "x", goOS: goOS, goArch: goArch, fileManager: fileManager
        ) else { return nil }
        let cacheRoot = anyVersion
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let versions = try? fileManager.contentsOfDirectory(atPath: cacheRoot.path) else {
            return nil
        }
        for version in versions.sorted(by: >) where version != excludingVersion {
            if let url = try? Workspace.remoteDaemonCachedBinaryURL(
                version: version, goOS: goOS, goArch: goArch, fileManager: fileManager
            ), isExecutableFile(url) {
                return url
            }
        }
        return nil
    }

    private func isExecutableFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            && !isDir.boolValue
            && fileManager.isExecutableFile(atPath: url.path)
    }

    private func hostPlatform() -> (goOS: String, goArch: String) {
#if arch(arm64)
        return ("darwin", "arm64")
#else
        return ("darwin", "amd64")
#endif
    }

    private func appVersionString() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
