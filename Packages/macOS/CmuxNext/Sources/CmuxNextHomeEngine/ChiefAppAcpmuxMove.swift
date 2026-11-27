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
/// here), else stopped. Then the Chief home's own daemon ends with its agents, unless a named
/// Chief of the home (`c/<id>`, cmux-tui chief_brains.rs) still runs on it or one of its sessions
/// is in a turn (a subagent the Chief started still working): then a later start ends it. Never
/// the app's daemon.
nonisolated struct ChiefAppAcpmuxMove: Sendable {
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
    nonisolated struct Plan: Equatable {
        /// Restart the running host: it is not one this app launched on the app's acpmux.
        var restartHost = false
        /// End the Chief home's own daemon (it is the Chief's alone).
        var endOwnDaemon = false
    }

    /// The plan for a host `hostPID` (nil: none runs) whose executable is gone or not
    /// (`hostReplaced`), the launch mark (`markedPID`, `markedHome`), the app's acpmux home, whether
    /// the Chief home's own daemon may answer (its socket is there) and whether a named Chief of
    /// the home runs (it shares that daemon).
    /// Rust `chief_home.acpmux_plan`; when the rules cannot run, nothing is restarted or ended.
    static func plan(hostPID: pid_t?, hostReplaced: Bool, markedPID: pid_t?, markedHome: String?, appHome: String,
                     ownDaemonPresent: Bool, namedChiefsRun: Bool) -> Plan {
        struct Request: Encodable {
            let hostPID: Int32?
            let hostReplaced: Bool
            let markedPID: Int32?
            let markedHome: String?
            let appHome: String
            let ownDaemonPresent: Bool
            let namedChiefsRun: Bool
        }
        struct Reply: Decodable { let restartHost: Bool; let endOwnDaemon: Bool }
        let request = Request(hostPID: hostPID, hostReplaced: hostReplaced, markedPID: markedPID, markedHome: markedHome,
                              appHome: appHome, ownDaemonPresent: ownDaemonPresent, namedChiefsRun: namedChiefsRun)
        guard let reply: Reply = try? ChiefHomeRules().call("acpmux_plan", request) else { return Plan() }
        return Plan(restartHost: reply.restartHost, endOwnDaemon: reply.endOwnDaemon)
    }

    var markFile: URL { Self.markFile(home) }

    /// `state/host.acpmux` (Rust `chief_home.acpmux_mark_file`).
    static func markFile(_ home: ChiefHome) -> URL {
        struct Request: Encodable { let root: String }
        struct Reply: Decodable { let path: String }
        guard let reply: Reply = try? ChiefHomeRules().call("acpmux_mark_file", Request(root: home.root.path)) else {
            return home.root.appendingPathComponent("state/host.acpmux")
        }
        return URL(fileURLWithPath: reply.path)
    }

    /// The launch mark's pid and acpmux home (the file read here, its lines by Rust `chief_home.acpmux_read_mark`).
    static func readMark(_ home: ChiefHome) -> (pid: pid_t?, home: String?) {
        // concurrency-allow: a small local file read, off the main actor in `HomeBrainHost.start`
        let text = (try? String(contentsOf: markFile(home), encoding: .utf8)) ?? ""
        struct Request: Encodable { let text: String }
        struct Reply: Decodable { let pid: Int32?; let home: String? }
        guard let reply: Reply = try? ChiefHomeRules().call("acpmux_read_mark", Request(text: text)) else { return (nil, nil) }
        return (reply.pid, reply.home)
    }

    /// Whether running host `hostPID` is the one this app launched (`markedPID`) on an acpmux
    /// other than the Chief home's own (`markedHome`, `ownHome`; Rust `chief_home.acpmux_on_app`).
    static func onAppAcpmux(hostPID: pid_t?, markedPID: pid_t?, markedHome: String?, ownHome: String) -> Bool {
        struct Request: Encodable { let hostPID: Int32?; let markedPID: Int32?; let markedHome: String?; let ownHome: String }
        struct Reply: Decodable { let onAppAcpmux: Bool }
        let request = Request(hostPID: hostPID, markedPID: markedPID, markedHome: markedHome, ownHome: ownHome)
        return ((try? ChiefHomeRules().call("acpmux_on_app", request)) as Reply?)?.onAppAcpmux ?? false
    }

    /// With the kill switch (`CMUX_CHIEF_OWN_ACPMUX=1`), a running host this app launched on the
    /// app's acpmux restarts on the Chief home's own daemon, where the Chief's tabs then attach:
    /// asked to hand off when idle when it takes that, else stopped. Returns false when it was
    /// asked to hand off: it keeps its turn, and its exit brings the next start.
    @concurrent static func leaveAppAcpmux(home: ChiefHome) async -> Bool {
        let mark = readMark(home)
        guard onAppAcpmux(hostPID: ChiefHostStop.runningHostPID(home: home), markedPID: mark.pid, markedHome: mark.home,
                          ownHome: home.acpmuxHome.path) else { return true }
        if let asked = ChiefHostStop.askToHandOffWhenIdle(home: home) {
            logger.info("Chief host \(asked) is on the app's acpmux, the kill switch is on; it hands off when its turn ends")
            return false
        }
        if let pid = await ChiefHostStop.stop(home: home) {
            logger.info("Chief host \(pid) is on the app's acpmux, the kill switch is on; stopped it")
            _ = await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
        }
        return true
    }

    /// Records that this app launched host `pid` on the app's acpmux.
    func mark(pid: pid_t) {
        struct Request: Encodable { let pid: Int32; let appHome: String }
        struct Reply: Decodable { let text: String }
        // No mark when the rules cannot run: the next start restarts the host, as for any unmarked one.
        guard let reply: Reply = try? ChiefHomeRules().call("acpmux_mark_text", Request(pid: pid, appHome: app.home.path)) else { return }
        try? FileManager.default.createDirectory(at: markFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? reply.text.write(to: markFile, atomically: true, encoding: .utf8)
    }

    /// Runs the plan. Returns false when the running host was asked to hand off when idle: it
    /// keeps running until its turn ends, and its exit brings the next start here.
    @concurrent func run() async -> Bool {
        let mark = Self.readMark(home)
        let hostPID = ChiefHostStop.runningHostPID(home: home)
        let ownSocket = own.map(\.socketPath).flatMap { $0 == app.socketPath ? nil : $0 }
        let plan = Self.plan(hostPID: hostPID, hostReplaced: hostPID.map(Self.executableGone) ?? false,
                             markedPID: mark.pid, markedHome: mark.home,
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
            guard Self.idle(await AcpmuxQuit.census(own)) else {
                Self.logger.info("Chief's own acpmux at \(own.home.path, privacy: .public) may have a session in a turn; it ends at a later start")
                return true
            }
            let result = await AcpmuxQuit.endAgents(own, keep: .nothing)
            Self.logger.info("Chief's own acpmux at \(own.home.path, privacy: .public) ended: \(String(describing: result), privacy: .public)")
        }
        return true
    }

    /// Whether no session of a daemon is in a turn, the Chief's own included: ending it then
    /// stops no work. An unknown census (nil: the daemon did not answer in time, perhaps busy)
    /// is not idle: a later start ends it.
    static func idle(_ census: AcpmuxSessionCensus?) -> Bool {
        struct Census: Encodable { let inTurn: Int; let chiefInTurn: Bool }
        struct Request: Encodable { let census: Census? }
        struct Reply: Decodable { let idle: Bool }
        let request = Request(census: census.map { Census(inTurn: $0.inTurn, chiefInTurn: $0.chiefInTurn) })
        return ((try? ChiefHomeRules().call("acpmux_idle", request)) as Reply?)?.idle ?? false
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
