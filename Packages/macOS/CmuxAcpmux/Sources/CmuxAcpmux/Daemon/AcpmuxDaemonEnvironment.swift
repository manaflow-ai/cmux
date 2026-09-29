import Foundation

/// Where the acpmux daemon lives and how to start it.
///
/// Release builds share the user's daemon (`~/.acpmux`, honoring `ACPMUX_HOME` and
/// `ACPMUX_SOCKET`). Tagged DEV builds get a private home under the tag's Application
/// Support directory so they never touch the user's daemon or its sessions.
public struct AcpmuxDaemonEnvironment: Sendable, Equatable {
    /// The Unix socket the client connects to.
    public var socketPath: String
    /// The daemon home. `nil` lets the daemon use its default (`~/.acpmux`).
    public var homeDirectory: String?
    /// Executables to try in order when the daemon must be started.
    public var executableCandidates: [String]
    /// Extra `daemon run` arguments.
    public var daemonArguments: [String]
    /// Whether this environment is isolated for a tagged DEV build.
    public var isIsolated: Bool

    /// Creates an environment.
    public init(
        socketPath: String,
        homeDirectory: String?,
        executableCandidates: [String],
        daemonArguments: [String],
        isIsolated: Bool
    ) {
        self.socketPath = socketPath
        self.homeDirectory = homeDirectory
        self.executableCandidates = executableCandidates
        self.daemonArguments = daemonArguments
        self.isIsolated = isIsolated
    }

    /// Resolves the environment for this app instance.
    ///
    /// - Parameters:
    ///   - tag: The cmux DEV tag, or `nil`/empty for a release build.
    ///   - bundledExecutable: `cmux.app/Contents/Resources/bin/acpmux`, when bundled.
    ///   - applicationSupportDirectory: The per-bundle Application Support directory.
    ///   - processEnvironment: The app's environment, for `ACPMUX_*` overrides and `PATH`.
    ///   - userHome: The user's home directory.
    ///   - userID: The numeric user id, used for the short-socket fallback name.
    public static func resolve(
        tag: String?,
        bundledExecutable: URL?,
        applicationSupportDirectory: URL,
        processEnvironment: [String: String],
        userHome: URL,
        userID: UInt32
    ) -> AcpmuxDaemonEnvironment {
        let candidates = executableCandidates(
            bundled: bundledExecutable,
            path: processEnvironment["PATH"],
            userHome: userHome
        )
        if let tag = tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            let home = applicationSupportDirectory.appendingPathComponent("acpmux", isDirectory: true).path
            return AcpmuxDaemonEnvironment(
                socketPath: socketPath(home: home, override: nil, userID: userID),
                homeDirectory: home,
                executableCandidates: candidates,
                // The user's daemon owns the default web port; an isolated daemon takes any free one.
                daemonArguments: ["--listen", "127.0.0.1:0"],
                isIsolated: true
            )
        }
        let explicitHome = processEnvironment["ACPMUX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let home = explicitHome ?? userHome.appendingPathComponent(".acpmux", isDirectory: true).path
        return AcpmuxDaemonEnvironment(
            socketPath: socketPath(home: home, override: processEnvironment["ACPMUX_SOCKET"], userID: userID),
            homeDirectory: explicitHome,
            executableCandidates: candidates,
            daemonArguments: [],
            isIsolated: false
        )
    }

    /// The daemon log file, which ``AcpmuxDaemonLauncher`` watches for readiness.
    public func logPath(userHome: URL) -> String {
        let home = homeDirectory ?? userHome.appendingPathComponent(".acpmux", isDirectory: true).path
        return (home as NSString).appendingPathComponent("daemon.log")
    }

    /// Environment variables for a daemon child process.
    public func childEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["ACPMUX_SOCKET"] = socketPath
        if let homeDirectory { environment["ACPMUX_HOME"] = homeDirectory }
        return environment
    }

    /// Mirrors acpmux `config::socket_path`: `home/acpmux.sock`, or a short `/tmp` name
    /// when that path would not fit in `sockaddr_un`.
    static func socketPath(home: String, override: String?, userID: UInt32) -> String {
        if let override, !override.isEmpty { return override }
        let path = (home as NSString).appendingPathComponent("acpmux.sock")
        guard path.utf8.count >= 96 else { return path }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in home.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "/tmp/acpmux-\(userID)-\(String(format: "%016llx", hash)).sock"
    }

    static func executableCandidates(bundled: URL?, path: String?, userHome: URL) -> [String] {
        var candidates: [String] = []
        if let bundled { candidates.append(bundled.path) }
        for directory in (path ?? "").split(separator: ":") where !directory.isEmpty {
            candidates.append((String(directory) as NSString).appendingPathComponent("acpmux"))
        }
        // GUI apps launched by LaunchServices get a minimal PATH; add the usual install locations.
        candidates.append(userHome.appendingPathComponent(".local/bin/acpmux").path)
        candidates.append(userHome.appendingPathComponent(".cargo/bin/acpmux").path)
        candidates.append("/opt/homebrew/bin/acpmux")
        candidates.append("/usr/local/bin/acpmux")
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}
