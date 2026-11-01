public import CmuxNextCompat
public import Foundation
import os

extension DaemonLauncher {
    private static let buildLogger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")

    /// The app daemon's session and state directory of `build` (per-build
    /// isolation S3, cx-is1kf.4): ``BuildIdentity/appSession`` and
    /// ``BuildIdentity/daemonStateDirectory(appSupport:)`` under
    /// `<applicationSupport>/cmux`. With `log` (the app launcher), a build
    /// whose names are of its key (the untagged DEV build among them) logs
    /// them, so a developer can find its session.
    public static func appNames(build: BuildIdentity, applicationSupport: URL = applicationSupportDirectory(),
                                log: Bool = false) -> (session: String, stateDirectory: URL?) {
        let session = build.appSession ?? "cmux-app"
        let stateDirectory = build.daemonStateDirectory(
            appSupport: applicationSupport.appendingPathComponent("cmux", isDirectory: true))
        // An untagged NIGHTLY, RC or staging build keeps the old shared session it ran
        // before cx-6so.41, once adopted (cx-r650e): `cmux-app` in cmux-tui's default root.
        if LegacyChannelSession(applicationSupport: applicationSupport)
            .adopts(bundleID: build.bundleID, session: session, stateDirectory: stateDirectory) {
            return (LegacyChannelSession.session, nil)
        }
        if log, !build.keepsAppNames {
            buildLogger.notice(
                "build \(build.key, privacy: .public) has per-build daemon session \(session, privacy: .public), state \(stateDirectory?.path ?? "default", privacy: .public)")
        }
        return (session, stateDirectory)
    }

    /// Build commit of the bundled binary (`cmux 0.1.0 (<commit>; ghostty …)`).
    public func bundledBuildCommit() async throws -> String? {
        let result = try await ProcessRunner.run(executable: configuration.binary, arguments: ["--version"],
                                                 environment: nil, timeout: .seconds(5), clock: clock)
        return Self.parseBuildCommit(String(decoding: result.stdout, as: UTF8.self))
    }

    /// Build of the bundled binary (`cmux --version --json`: `build_commit` and `build_identity`),
    /// for the version handoff; nil when the binary does not answer with that JSON.
    /// A binary older than `--version --json` (an external `CMUX_NEXT_TUI_BIN`) gets its commit
    /// from the `--version` text, as before.
    public func bundledBuild() async throws -> DaemonBuildStamp? {
        let result = try await ProcessRunner.run(executable: configuration.binary, arguments: ["--version", "--json"],
                                                 environment: nil, timeout: .seconds(5), clock: clock)
        if let stamp = DaemonBuildStamp(versionJSON: result.stdout) { return stamp }
        return try await bundledBuildCommit().map { DaemonBuildStamp(commit: $0, id: nil) }
    }

    static func parseBuildCommit(_ version: String) -> String? {
        guard version.contains("(") else { return nil }
        let commit = version.drop { $0 != "(" }.dropFirst().prefix { $0.isHexDigit }
        return commit.count >= 7 ? String(commit) : nil
    }

    /// True when the running daemon is another build than the bundled binary
    /// (``versionDecision(running:bundled:)``), so the app should hand it off.
    public func isStale(_ identity: DaemonIdentity) async -> Bool {
        let bundled = try? await bundledBuild()
        guard case .restart = Self.versionDecision(running: DaemonBuildStamp(identity: identity), bundled: bundled) else { return false }
        return true
    }
}
