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
    /// The `detail` is user-facing copy (it lands in the chat surface's
    /// status UI), so it must be localized and free of implementation
    /// internals; technical specifics go to the debug log instead.
    enum Outcome: Sendable {
        case found(URL, Provenance)
        case unavailable(detail: String)
    }

    /// Where a found binary came from. Consumers that shell out to verbs the
    /// `hello` capability handshake cannot vouch for (the launch-side
    /// `agent-hook-emit` injection) gate on this: an old cached daemon
    /// invoked with an unknown verb falls through to its CLI path and fails
    /// hooks, so only binaries provably carrying the verb may be injected.
    enum Provenance: Equatable, Sendable {
        /// `CMUX_REMOTE_DAEMON_BINARY` dev override (explicit opt-in).
        case explicitOverride
        /// The checksum-verified `remote-daemons` cache, at `version`.
        case cached(version: String)
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
                return .found(override, .explicitOverride)
            }
#if DEBUG
            cmuxDebugLog("agentChat.locator.overrideInvalid path=\(override.path)")
#endif
            return .unavailable(detail: String(
                localized: "agentChat.daemon.overrideInvalid",
                defaultValue: "The configured agent daemon binary is missing or can't be run."
            ))
        }
        let (goOS, goArch) = hostPlatform()
        let version = Self.appVersionString()
        if let exact = try? Workspace.remoteDaemonCachedBinaryURL(
            version: version, goOS: goOS, goArch: goArch, fileManager: fileManager
        ), isExecutableFile(exact) {
            return .found(exact, .cached(version: version))
        }
        if let (fallback, fallbackVersion) = newestCachedBinary(goOS: goOS, goArch: goArch, excludingVersion: version) {
            return .found(fallback, .cached(version: fallbackVersion))
        }
#if DEBUG
        cmuxDebugLog("agentChat.locator.noCachedBinary platform=\(goOS)-\(goArch) version=\(version)")
#endif
        return .unavailable(detail: String(
            localized: "agentChat.daemon.notCached",
            defaultValue: "The agent chat daemon isn't installed yet. Connect to a remote host once with cmux ssh to install it."
        ))
    }

    private func explicitOverrideURL() -> URL? {
        guard environment["CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD"] == "1" else { return nil }
        guard let path = environment["CMUX_REMOTE_DAEMON_BINARY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }

    /// Orders dotted versions numerically per component ("0.10.0" beats
    /// "0.9.0", which plain lexicographic sorting gets backwards); missing
    /// components count as 0 and non-numeric components fall back to string
    /// comparison.
    static func isVersionNewer(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".")
        let right = rhs.split(separator: ".")
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : "0"
            let rightPart = index < right.count ? right[index] : "0"
            if leftPart == rightPart { continue }
            if let leftNumber = Int(leftPart), let rightNumber = Int(rightPart) {
                return leftNumber > rightNumber
            }
            return leftPart > rightPart
        }
        return false
    }

    /// Scans the cache root for the newest other version holding a runnable
    /// binary for this platform.
    private func newestCachedBinary(
        goOS: String, goArch: String, excludingVersion: String
    ) -> (url: URL, version: String)? {
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
        for version in versions.sorted(by: Self.isVersionNewer) where version != excludingVersion {
            if let url = try? Workspace.remoteDaemonCachedBinaryURL(
                version: version, goOS: goOS, goArch: goArch, fileManager: fileManager
            ), isExecutableFile(url) {
                return (url, version)
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

    static func appVersionString() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
