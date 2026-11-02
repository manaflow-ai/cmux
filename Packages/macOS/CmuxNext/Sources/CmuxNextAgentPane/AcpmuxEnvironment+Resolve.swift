public import CmuxNextCompat
public import Foundation

/// Which acpmux executable this app runs, and whether it trusts it: the
/// search order (the bundled binary, then `PATH`, then the usual install
/// directories; a DEBUG override wins, AcpmuxEnvironment+DebugOverride.swift)
/// and the refusal of an executable the app's team did not sign
/// (``AcpmuxServerPeer/executableSignedByAppTeam(_:team:)``). The Computer Use
/// helper admits bridges by this executable's signature or cdhash, and the
/// server peer check compares against it. Kept out of AcpmuxEnvironment.swift,
/// unchanged, so that the risk tier grades this trust decision on its own.
///
/// The members of AcpmuxEnvironment.swift it uses are named `AcpmuxEnvironment.<member>`, so the
/// defaults guard (scripts/ci/defaults_guard.py), which follows same-file names and `Type.member`
/// references, still tracks them as dependencies of `resolve`.
nonisolated extension AcpmuxEnvironment {
    /// Resolves the environment of `build` (nil: no build, the shared home),
    /// or nil when no `acpmux` executable exists. `bundledBinDirectory` is the
    /// app's `Contents/Resources/bin`. A Debug compile takes a test root for
    /// `~/.acpmux` from `CMUX_NEXT_ACPMUX_ROOT` (tests only).
    public static func resolve(
        build: BuildIdentity?,
        bundledBinDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: UInt32 = getuid(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        launchEnvironment: [String: String] = [:]
    ) -> AcpmuxEnvironment? {
        // DEBUG only: `CMUX_NEXT_ACPMUX_BIN` wins (AcpmuxEnvironment+DebugOverride.swift).
        // Release passes nil, so it compiles no read of it.
        #if DEBUG
        let executableOverride = debugExecutableOverride
        #else
        let executableOverride: URL? = nil
        #endif
        return resolve(build: build, bundledBinDirectory: bundledBinDirectory, environment: environment, userHome: userHome,
                       uid: uid, isExecutable: isExecutable, launchEnvironment: launchEnvironment,
                       executableOverride: executableOverride, teamIdentifier: AcpmuxServerPeer.ownTeam,
                       isTrustedExecutable: AcpmuxServerPeer.executableSignedByAppTeam)
    }

    /// ``resolve(build:bundledBinDirectory:environment:userHome:uid:isExecutable:launchEnvironment:)`` with
    /// the executable override given: tests pass nil, so a developer's exported
    /// `CMUX_NEXT_ACPMUX_BIN` cannot change what they resolve.
    static func resolve(
        build: BuildIdentity?,
        bundledBinDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: UInt32 = getuid(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        launchEnvironment: [String: String] = [:],
        personsHome: URL? = AcpmuxEnvironment.testProcessPersonsHome,
        executableOverride: URL?,
        teamIdentifier: String? = AcpmuxServerPeer.ownTeam,
        isTrustedExecutable: (URL, String) -> Bool = { AcpmuxServerPeer.executableSignedByAppTeam($0, team: $1) }
    ) -> AcpmuxEnvironment? {
        guard let executable = executableOverride
            ?? executableCandidates(bundledBinDirectory: bundledBinDirectory, environment: environment, userHome: userHome)
            .first(where: { isExecutable($0.path) }) else { return nil }
        if let teamIdentifier, !isTrustedExecutable(executable, teamIdentifier) { return nil }
        let root = AcpmuxEnvironment.testRoot(environment) ?? AcpmuxEnvironment.sharedRoot(userHome: userHome)
        let ownHome = build?.acpmuxHome(root: root) ?? root
        let home: URL
        let customHome = environment["ACPMUX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        if let customHome {
            home = URL(fileURLWithPath: customHome, isDirectory: true)
        } else {
            home = ownHome
        }
        // A test process never reaches the person's own daemons (AcpmuxEnvironment+TestGuard.swift).
        if let personsHome, Self.isPersonsAcpmuxHome(home, personsHome: personsHome) {
            Self.refuseInTest()
            return nil
        }
        let configured = customHome == nil ? nil : environment["ACPMUX_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        let socket = AcpmuxEnvironment.socketPath(configured: configured, home: home, uid: uid)
        var childEnvironment = ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket, "ACPMUX_LOCAL_ROUTER": "1",
                                "ACPMUX_SECRET_TOOLS": "1"]
        childEnvironment.merge(launchEnvironment) { _, new in new }
        for key in AcpmuxEnvironment.agentLaunchKeys {
            if let value = environment[key], !value.isEmpty { childEnvironment[key] = value }
        }
        if let cli = bundledBinDirectory?.appendingPathComponent("cmux").path, isExecutable(cli) {
            childEnvironment["CMUX_BUNDLED_CLI_PATH"] = cli
        }
        return AcpmuxEnvironment(
            executable: executable, home: home, socketPath: socket,
            daemonArguments: ownHome == root ? [] : ["--listen", "127.0.0.1:0"], childEnvironment: childEnvironment,
            passesPersonKeyAtSpawn: teamIdentifier == nil
        )
    }

    /// The usual install directories, searched after `PATH`. The pane names
    /// them when acpmux is missing, so they are written as a user types them.
    static let installDirectories = ["~/.local/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    /// Search order: the bundled binary, then `PATH`, then the usual install
    /// directories an app launched from Finder does not have on its `PATH`.
    static func executableCandidates(bundledBinDirectory: URL?, environment: [String: String], userHome: URL) -> [URL] {
        var directories: [String] = []
        if let bundled = bundledBinDirectory { directories.append(bundled.path) }
        directories += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += installDirectories.map { directory in
            directory.hasPrefix("~/") ? userHome.appendingPathComponent(String(directory.dropFirst(2))).path : directory
        }
        var seen: Set<String> = []
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("acpmux") }
    }
}
