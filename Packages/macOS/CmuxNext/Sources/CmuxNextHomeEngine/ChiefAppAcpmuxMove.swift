import CmuxNextAgentPane
import Darwin
import Foundation
import os

/// Moves a Chief that uses the app's acpmux (``ChiefHome/usesAppAcpmux``) off the daemon of its
/// own, at each `HomeBrainHost.start`. An update relaunch does not stop the Chief host, so without
/// this the app would reuse a host of the previous build that still runs, in local mode, on
/// `<Chief home>/acpmux` (perhaps from a replaced bundle), for good.
///
/// A host counts as on the app's acpmux only when this app launched it there: `state/host.acpmux`
/// names its pid and the app's acpmux home (written at launch, ``mark(pid:)``). Any other running
/// host (an older build's, a `cmux chief` CLI's, or one whose executable is gone) is restarted:
/// asked to hand off when idle when it takes that (its exit restarts the start, which comes back
/// here), else stopped. Then the Chief home's own daemon ends, unless a named Chief of the home
/// (`c/<id>`, cmux-tui chief_brains.rs) still runs on it. Never the app's daemon.
struct ChiefAppAcpmuxMove: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    let home: ChiefHome
    /// The app's acpmux, which the Chief uses.
    let app: AcpmuxEnvironment
    /// The Chief home's own acpmux (`home.acpmuxHome`), nil without an acpmux executable.
    let own: AcpmuxEnvironment?

    init(home: ChiefHome, app: AcpmuxEnvironment) {
        self.home = home
        self.app = app
        own = AcpmuxEnvironment.resolve(build: nil, bundledBinDirectory: app.executable.deletingLastPathComponent(),
                                        environment: ["ACPMUX_HOME": home.acpmuxHome.path])
    }

    /// What a start does before it reuses or launches a host.
    struct Plan: Equatable {
        /// Restart the running host: it is not one this app launched on the app's acpmux.
        var restartHost = false
        /// End the Chief home's own daemon (it is the Chief's alone).
        var endOwnDaemon = false
    }

    /// The plan for a host `hostPID` (nil: none runs) whose executable is gone or not
    /// (`hostReplaced`), the launch mark (`markedPID`, `markedHome`), the app's acpmux home, whether
    /// the Chief home's own daemon may answer (its socket is there) and whether a named Chief of
    /// the home runs (it shares that daemon).
    static func plan(hostPID: pid_t?, hostReplaced: Bool, markedPID: pid_t?, markedHome: String?, appHome: String,
                     ownDaemonPresent: Bool, namedChiefsRun: Bool) -> Plan {
        var plan = Plan()
        if let hostPID {
            plan.restartHost = hostReplaced || markedPID != hostPID || markedHome != appHome
        }
        plan.endOwnDaemon = ownDaemonPresent && !namedChiefsRun
        return plan
    }

    var markFile: URL { home.root.appendingPathComponent("state/host.acpmux") }

    /// Records that this app launched host `pid` on the app's acpmux.
    func mark(pid: pid_t) {
        try? FileManager.default.createDirectory(at: markFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid)\n\(app.home.path)\n".write(to: markFile, atomically: true, encoding: .utf8)
    }

    /// Runs the plan. Returns false when the running host was asked to hand off when idle: it
    /// keeps running until its turn ends, and its exit brings the next start here.
    @concurrent func run() async -> Bool {
        // concurrency-allow: a small local file read, off the main actor in `HomeBrainHost.start`
        let lines = ((try? String(contentsOf: markFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let hostPID = ChiefHostStop.runningHostPID(home: home)
        let ownSocket = own.map(\.socketPath).flatMap { $0 == app.socketPath ? nil : $0 }
        let plan = Self.plan(hostPID: hostPID, hostReplaced: hostPID.map(Self.executableGone) ?? false,
                             markedPID: lines.first.flatMap { pid_t($0) }, markedHome: lines.dropFirst().first,
                             appHome: app.home.path,
                             ownDaemonPresent: ownSocket.map { FileManager.default.fileExists(atPath: $0) } ?? false,
                             namedChiefsRun: namedChiefsRun())
        if plan.restartHost {
            if let asked = ChiefHostStop.askToHandOffWhenIdle(home: home) {
                Self.logger.info("Chief host \(asked) is not on the app's acpmux; it hands off when its turn ends")
                return false
            }
            if let pid = await ChiefHostStop.stop(home: home) {
                Self.logger.info("Chief host \(pid) is not on the app's acpmux; stopped it")
                _ = await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
            }
        }
        if plan.endOwnDaemon, let own, own.home.standardizedFileURL != app.home.standardizedFileURL {
            let result = await AcpmuxQuit.endAgents(own, keep: .nothing)
            Self.logger.info("Chief's own acpmux at \(own.home.path, privacy: .public) ended: \(String(describing: result), privacy: .public)")
        }
        return true
    }

    /// Whether process `pid` runs an executable whose file is gone (an update replaced the bundle).
    static func executableGone(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        guard let path = ChiefHostStop.executablePath(pid) else { return true }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// Whether a named Chief of this home (`c/<id>`) holds its host lock: it runs on the Chief
    /// home's own acpmux (cmux-tui chief_brains.rs `OPTCHAT_ACPMUX_SHARED`).
    private func namedChiefsRun() -> Bool {
        let named = home.root.appendingPathComponent("c", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: named, includingPropertiesForKeys: nil)) ?? []
        return entries.contains { ChiefMigration.lockHeld(at: $0.appendingPathComponent("state/host.lock")) }
    }
}
