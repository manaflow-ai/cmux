import CmuxNextCompat
import CmuxNextDaemon
public import Foundation
import AppKit
import os

/// The Privacy & Security rows (Screen Recording, Accessibility, Input Monitoring, and the
/// PostEvent half of Accessibility) that helpers cmux NEXT no longer ships left behind, removed
/// once per app version at launch (the App's `LaunchCleanup`), off the main thread, with
/// `tccutil reset <service> <bundle id>` in the person's own scope (no sudo, no prompt).
///
/// After it, the one cmux row left for these grants is the build's Screen Sharing helper,
/// `<app id>.screen-sharing` (scripts/ci/check-screen-share-identity.sh), plus the app's own id
/// while the app still asks in its own name.
///
/// The retired holders, from the tree and its history:
/// - cmux Remote: `com.cmuxterm.remote` and `com.cmuxterm.remote.dev`
///   (cmux-tui-core `remote_host/macos.rs` `BUNDLE_IDS`; the pinned asset is the `.dev` one,
///   scripts/cmux-next/embed-cmux-remote-dev.sh). #49827 stops embedding it in every build. While
///   this build still embeds a cmux Remote bundle (a DEV build before #49827) both are kept.
/// - the legacy Computer Use helper `com.cmuxterm.cua` (and its tagged dev id
///   `com.cmuxterm.cua.dev`), which #37003 deleted from cmux NEXT. Classic cmux still ships it
///   (main `ComputerUseHelperTrust.bundleIdentifier`, scripts/ci/sign-cua-helper-dev.sh), so these
///   two are reset only when no classic cmux is on this Mac: no `com.cmuxterm.app` known to
///   LaunchServices (a classic that runs or ever ran is registered there), no /Applications/cmux.app
///   or ~/Applications/cmux.app, and no classic helper stage (`cmux/cmux-cua` in Application
///   Support, main `ComputerUseRuntimePaths`). Any one of those keeps them; a later version retries.
///   No process scan: cmux-next never scans processes (plans/cmux-next/pty-holder.md).
///
/// Never reset here: the app's own id (iPhone viewers, Voice Room, dictation and onboarding still
/// ask in its name after #49826 and #49829), `com.cmuxterm.app` and every other classic id, and the
/// Screen Sharing helper.
///
/// `tccutil` finds an id through LaunchServices; for a holder whose bundle is gone from disk it
/// exits non-zero ("No such bundle identifier") and the row stays. That outcome is logged, not
/// retried: the version marker is written once every holder was tried, or kept for a reason a
/// later version may clear.
public nonisolated struct RetiredPermissionRows: Sendable {
    /// One retired holder and what keeps it.
    struct Holder: Sendable, Equatable {
        let bundleID: String
        /// Classic cmux uses the id too: reset only with no classic cmux on this Mac.
        let sharedWithClassic: Bool
        /// Bundles in this app's `Contents/Library` that still use the holder: while one is
        /// embedded, the holder is live in this build and is kept.
        let liveWhileEmbedded: [String]
    }

    /// The TCC services each retired holder could have asked for.
    static let services = ["ScreenCapture", "Accessibility", "ListenEvent", "PostEvent"]

    static let holders: [Holder] = {
        let remote = ["cmux Remote.app", "cmux Remote (dev).app"]
        return [
            Holder(bundleID: "com.cmuxterm.remote", sharedWithClassic: false, liveWhileEmbedded: remote),
            Holder(bundleID: "com.cmuxterm.remote.dev", sharedWithClassic: false, liveWhileEmbedded: remote),
            Holder(bundleID: "com.cmuxterm.cua", sharedWithClassic: true, liveWhileEmbedded: []),
            Holder(bundleID: "com.cmuxterm.cua.dev", sharedWithClassic: true, liveWhileEmbedded: []),
        ]
    }()

    /// The app version (`<short>(<build>)`) the cleanup last ran for, in this app's defaults.
    static let doneKey = "cmux.tcc.retiredRows.doneVersion"

    /// Why a holder was left alone this launch.
    public enum Kept: String, Sendable, Equatable {
        case embedded, classic
    }

    /// What one launch did: `reset` and `failed` are `<service> <bundle id>` (failed with
    /// tccutil's message), `kept` the holders left alone.
    public struct Report: Sendable, Equatable {
        public var version: String
        public var reset: [String] = []
        public var failed: [String] = []
        public var kept: [String: Kept] = [:]
    }

    /// What the cleanup reads and runs on this Mac; tests pass their own.
    struct Mac: Sendable {
        var version: @Sendable () -> String?
        /// Whether this app's `Contents/Library` holds the named bundle.
        var embeds: @Sendable (String) -> Bool
        var classicPresent: @Sendable () -> Bool
        /// Runs `tccutil reset <service> <bundle id>`: nil on success, else its message.
        var reset: @Sendable (_ service: String, _ bundleID: String) async -> String?
    }

    /// The defaults suite holding the marker; nil is this app's own domain. Tests pass a suite.
    let suiteName: String?
    let mac: Mac

    /// This app on this Mac.
    public init() {
        self.init(suiteName: nil, mac: .live)
    }

    init(suiteName: String?, mac: Mac) {
        self.suiteName = suiteName
        self.mac = mac
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "tcc-cleanup")

    /// Runs the cleanup on a background task. Its value is the report, nil when this version
    /// already ran it (or the bundle has no version).
    @discardableResult
    public func cleanUpInBackground() -> Task<Report?, Never> {
        // task-owner: at most 16 tccutil runs of 10 s each, once per app version, off the main thread; ends by itself
        Task.detached(priority: .utility) { [self] in await cleanUp() }
    }

    private func cleanUp() async -> Report? {
        let defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        guard let version = mac.version(), defaults.string(forKey: Self.doneKey) != version else { return nil }
        var report = Report(version: version)
        let classic = mac.classicPresent()
        for holder in Self.holders {
            if holder.liveWhileEmbedded.contains(where: mac.embeds) { report.kept[holder.bundleID] = .embedded; continue }
            if holder.sharedWithClassic && classic { report.kept[holder.bundleID] = .classic; continue }
            for service in Self.services {
                if let message = await mac.reset(service, holder.bundleID) {
                    report.failed.append("\(service) \(holder.bundleID): \(message)")
                } else {
                    report.reset.append("\(service) \(holder.bundleID)")
                }
            }
        }
        defaults.set(version, forKey: Self.doneKey)
        let kept = report.kept.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value.rawValue))" }.joined(separator: ", ")
        Self.logger.info("""
            retired TCC rows for \(version, privacy: .public): reset [\(report.reset.joined(separator: ", "), privacy: .public)] \
            failed [\(report.failed.joined(separator: "; "), privacy: .public)] kept [\(kept, privacy: .public)]
            """)
        return report
    }
}

nonisolated extension RetiredPermissionRows.Mac {
    /// This app, LaunchServices, classic's install and stage folders, and `/usr/bin/tccutil`.
    static let live = Self(
        version: {
            let info = Bundle.main.infoDictionary ?? [:]
            guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return nil }
            return "\(info["CFBundleShortVersionString"] as? String ?? "")(\(build))"
        },
        embeds: { name in
            FileManager.checked.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/\(name)").path)
        },
        classicPresent: {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cmuxterm.app") != nil { return true }
            let home = FileManager.default.homeDirectoryForCurrentUser
            // Classic's helper stage, `<Application Support>/cmux/cmux-cua` (main ComputerUseRuntimePaths).
            let stage = NextSupport().classicBundleFolder(bundleID: "cmux-cua")
            let paths = ["/Applications/cmux.app", home.appendingPathComponent("Applications/cmux.app").path, stage.path]
            return paths.contains { FileManager.checked.fileExists(atPath: $0) }
        },
        reset: { service, bundleID in
            do {
                let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tccutil"), arguments: ["reset", service, bundleID],
                                                         environment: nil, timeout: .seconds(10), clock: ContinuousClock())
                guard result.status != 0 else { return nil }
                let message = String(decoding: result.stderr + result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return "exit \(result.status)\(message.isEmpty ? "" : ": \(message)")"
            } catch {
                return String(describing: error)
            }
        }
    )
}
