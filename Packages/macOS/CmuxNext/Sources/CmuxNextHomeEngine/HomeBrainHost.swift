public import CmuxNextActions
public import CmuxNextCompat
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextHomeModel
public import Foundation
import os

/// Starts the local mux brain host (plans/cmux-next/home.md section 4) when
/// Home first opens: a detached process (its own process group, adopted by
/// launchd) that is a client of the daemon's conversation owner and of acpmux,
/// and listens on nothing. It outlives the app; its own pid lock keeps one
/// instance per mux home, so starting it again is harmless.
///
/// The host is the executable named by `CMUX_NEXT_MUX_HOST` (the TypeScript
/// `mux`, or a local optchat-chief build), else the OptChat Chief that the app
/// bundles as Contents/Resources/bin/optchat-chief
/// (scripts/cmux-next/bundle-optchat-chief.sh; Native/OptChat/optchat-chief,
/// chief-done.md check 7: every Chief turn follows OptChat). DEV, NIGHTLY,
/// RC and stable start it when it is bundled (`bundledChiefAllowed`); stable
/// ships it since the classic handoff (release.yml bundles it). Both keep the
/// `host --daemon-socket --mux-home` contract and one lock per mux home.
/// The mux home is this build's Chief home (`ChiefHome`, one Chief per
/// build); isolated launches (agent preflights, tests) get their own. The
/// host lock keeps one host per home: a second launch (or one `cmux chief`
/// started) exits at once. When the host dies while the app runs, Home
/// starts it again (`ChiefBrainWatch`).
public nonisolated struct HomeBrainHost: Sendable {
    let executable: URL
    let muxHome: URL
    let daemonSocket: String
    /// This app's control socket, so the mux's `cmux` calls reach this app (tagged builds included).
    let controlSocket: String
    let acpmux: AcpmuxEnvironment?
    /// The Chief runs on the app's own acpmux (``ChiefHome/usesAppAcpmux``): the host only
    /// waits for that daemon (`OPTCHAT_ACPMUX_SUPERVISED=1`), never starts, stops or hands it off.
    var usesAppAcpmux = false
    /// Starts the app's own acpmux when none runs (the local pane host's prewarm), before a host
    /// that only waits for it launches. Nil: nothing to start.
    public var ensureAppAcpmux: (@Sendable () async -> Void)?
    /// "cmux Files (dev)" in a DEV build that embeds it (docs/cmux-files-host.md): the host and the
    /// agents it starts then answer to that helper for Files and Folders, shared by every DEV build,
    /// as the app's own acpmux does. Nil in every other build, which runs the host as before.
    var filesHost: FilesHost?

    /// The OptChat Chief's file name in the app's Contents/Resources/bin.
    static let bundledChiefName = "optchat-chief"

    /// Every cmux channel starts the Chief it bundles: DEV (a Debug compile), NIGHTLY
    /// (`com.cmuxterm.app.nightly[.<tag>]`), RC and stable (`com.cmuxterm.app`, which the
    /// classic → cmux-next handoff ships with the Chief bundled). Another app's bundle id
    /// never starts it. Developer tools keep their own DEV and NIGHTLY rule (``DevTools``).
    public static func bundledChiefAllowed(bundleID: String?, isDebugBuild: Bool) -> Bool {
        nonisolated struct Request: Encodable { var bundleId: String?; var stableBundleId: String?; var isDebugBuild: Bool }
        nonisolated struct Reply: Decodable { var allowed: Bool }
        let request = Request(bundleId: bundleID, stableBundleId: stableBundleID, isDebugBuild: isDebugBuild)
        return (try? HomeRules.chiefBrain("bundled_chief_allowed", request) as Reply)?.allowed ?? false
    }

    /// The stable cmux bundle id; RC and NIGHTLY add a suffix to it.
    static let stableBundleID = "com.cmuxterm.app"

    /// Whether this app can start a host at all (`resolve` finds an executable).
    public static func canStart(environment: [String: String] = ProcessInfo.processInfo.environment,
                                bundledBinDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
                                bundledChiefAllowed: Bool = HomeBrainHost.bundledChiefAllowed(bundleID: Bundle.main.bundleIdentifier,
                                                                                              isDebugBuild: DevTools.isDebugBuild)) -> Bool {
        // The build-session kill switch: no Chief host, so no brain starts (cx-9ettq); the rules
        // name no candidate then.
        let plan = resolvePlan(environment: environment, bundledBinDirectory: bundledBinDirectory,
                               bundledChiefAllowed: bundledChiefAllowed, usesAppAcpmux: true, acpmuxHome: "")
        return plan?.candidates.contains { FileManager.default.isExecutableFile(atPath: $0) } ?? false
    }

    private nonisolated struct ResolvePlanRequest: Encodable {
        var environment: [String: String]
        var bundledBinDirectory: String?
        var bundledChiefAllowed: Bool
        var usesAppAcpmux: Bool
        var acpmuxHome: String
    }

    private nonisolated struct ResolvePlan: Decodable {
        var disabled: Bool
        /// The host executables to try, in order (`CMUX_NEXT_MUX_HOST`, then the bundled Chief).
        var candidates: [String]
        var acpmuxSet: [String: String]
        var acpmuxRemove: [String]
    }

    private static func resolvePlan(environment: [String: String], bundledBinDirectory: URL?, bundledChiefAllowed: Bool,
                                    usesAppAcpmux: Bool, acpmuxHome: String) -> ResolvePlan? {
        try? HomeRules.chiefBrain("host_resolve_plan", ResolvePlanRequest(
            environment: environment, bundledBinDirectory: bundledBinDirectory?.path, bundledChiefAllowed: bundledChiefAllowed,
            usesAppAcpmux: usesAppAcpmux, acpmuxHome: acpmuxHome))
    }

    /// Home's notice on this Mac's Chief while the build-session kill switch
    /// is on (cx-tgf4h): no host starts, so the Chief cannot answer; nil else.
    public static func agentsDisabledNotice(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        nonisolated struct Request: Encodable { var environment: [String: String] }
        nonisolated struct Reply: Decodable { var disabled: Bool }
        let reply = try? HomeRules.chiefBrain("agents_disabled", Request(environment: environment)) as Reply
        return reply?.disabled == true ? HomeStrings.chiefAgentsDisabled : nil
    }

    /// - Parameter appBuild: the build whose acpmux the app's panes use (`AppEnvironment.build`);
    ///   a Chief on the app's acpmux (``ChiefHome/usesAppAcpmux``) resolves the same daemon.
    public static func resolve(daemonSocket: String, controlSocket: String, home: ChiefHome, appBuild: BuildIdentity? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        bundledBinDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
                        bundledChiefAllowed: Bool = HomeBrainHost.bundledChiefAllowed(bundleID: Bundle.main.bundleIdentifier,
                                                                                      isDebugBuild: DevTools.isDebugBuild),
                        filesHost: ([String: String]) -> FilesHost? = { FilesHost.current(environment: $0) }) -> HomeBrainHost? {
        // NIGHTLY's Chief runs on the app's own acpmux (`~/.acpmux`, as the app's panes resolve
        // it); any other Chief on its Chief home's, never a tag's: a host started later by
        // another build finds the sessions its state names. The rules say which variables change.
        let usesAppAcpmux = home.usesAppAcpmux
        guard let plan = resolvePlan(environment: environment, bundledBinDirectory: bundledBinDirectory,
                                     bundledChiefAllowed: bundledChiefAllowed, usesAppAcpmux: usesAppAcpmux,
                                     acpmuxHome: home.acpmuxHome.path),
              !plan.disabled,
              let path = plan.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        var acpmuxEnvironment = environment
        acpmuxEnvironment.merge(plan.acpmuxSet) { $1 }
        for key in plan.acpmuxRemove { acpmuxEnvironment.removeValue(forKey: key) }
        var host = HomeBrainHost(executable: URL(fileURLWithPath: path), muxHome: home.muxHome, daemonSocket: daemonSocket, controlSocket: controlSocket,
                                 acpmux: AcpmuxEnvironment.resolve(build: usesAppAcpmux ? appBuild : nil, bundledBinDirectory: bundledBinDirectory,
                                                                   environment: acpmuxEnvironment))
        host.usesAppAcpmux = usesAppAcpmux
        host.filesHost = filesHost(environment)
        return host
    }

    /// This build's Chief home's mux home (`ChiefHome`); the engine bar,
    /// sidebar and files read it.
    public static func muxHome(tag: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        ChiefHome.resolve(tag: tag, environment: environment, userHome: userHome).muxHome
    }

    /// The shell prints the host's pid (with the helper, its launcher's, which forwards signals and
    /// exits with the host's status), so Home watches that process's exit.
    var arguments: [String] {
        nonisolated struct Request: Encodable { var executable: String; var filesHostExecutable: String?; var daemonSocket: String; var muxHome: String }
        nonisolated struct Reply: Decodable { var arguments: [String] }
        let request = Request(executable: executable.path, filesHostExecutable: filesHost?.executable.path,
                              daemonSocket: daemonSocket, muxHome: muxHome.path)
        // No argv: the shell runs nothing and prints no pid, so no host starts.
        return (try? HomeRules.chiefBrain("host_arguments", request) as Reply)?.arguments ?? []
    }

    var childEnvironment: [String: String] { childEnvironment(process: ProcessInfo.processInfo.environment) }

    /// The host's environment with `process` as the app's own (tests pass theirs).
    func childEnvironment(process: [String: String]) -> [String: String] {
        // The rules build it: PATH (``searchPath(home:)``), the token file, HOME, the host log,
        // CMUX_CHIEF_HOME (`cmux chief` in the brain's turns opens this Chief), the chief create
        // request's name and title (the owner refuses a different request under the same key),
        // ChiefAppLinks' constant links (the host outlives the app that started it), acpmux's
        // environment and ACPMUX_BIN, OPTCHAT_ACPMUX_SUPERVISED on the app's acpmux (never
        // OPTCHAT_ACPMUX_SHARED: its last Chief to leave ends every session of the daemon), the
        // app's USER, TMPDIR, MUX_HARNESS, DO_NOT_TRACK and CMUX_BUILD_SPACE, then the analytics ids.
        let analytics = Self.analyticsEnvironment(bundle: .main)
        let request = EnvironmentRequest(
            process: process, home: FileManager.default.homeDirectoryForCurrentUser.path, muxHome: muxHome.path,
            bundledBinDirectory: Self.bundledBinPath, userName: HomeChiefName.localUserName, chiefTitle: HomeStrings.chiefName,
            appLinks: ChiefAppLinks.hostEnvironment(ChiefHome(root: muxHome, isolated: false)),
            acpmuxEnvironment: acpmux?.childEnvironment, acpmuxExecutable: acpmux?.executable.path, usesAppAcpmux: usesAppAcpmux,
            buildSpaceKey: DaemonLauncher.buildSpaceKey, bundleId: analytics["CMUX_CHIEF_APP_BUNDLE_ID"],
            appVersion: analytics["CMUX_CHIEF_APP_VERSION"])
        nonisolated struct Reply: Decodable { var environment: [String: String] }
        return (try? HomeRules.chiefBrain("host_environment", request) as Reply)?.environment ?? [:]
    }

    private nonisolated struct EnvironmentRequest: Encodable {
        var process: [String: String]
        var home: String
        var muxHome: String
        var bundledBinDirectory: String?
        var userName: String
        var chiefTitle: String
        var appLinks: [String: String]
        var acpmuxEnvironment: [String: String]?
        var acpmuxExecutable: String?
        var usesAppAcpmux: Bool
        var buildSpaceKey: String?
        var bundleId: String?
        var appVersion: String?
    }

    /// This app's bundled bin folder (`Contents/Resources/bin`), as the host's PATH names it first.
    private static var bundledBinPath: String? { Bundle.main.resourceURL?.appendingPathComponent("bin").path }

    /// What the Chief's product analytics read from the app (docs/posthog/chief-product-analytics.md):
    /// the bundle id, whose preferences hold the person's `sendAnonymousTelemetry` choice (the host
    /// re-reads it every few minutes) and name the channel, and the app's version.
    static func analyticsEnvironment(bundle: Bundle) -> [String: String] {
        var variables: [String: String] = [:]
        variables["CMUX_CHIEF_APP_BUNDLE_ID"] = bundle.bundleIdentifier
        variables["CMUX_CHIEF_APP_VERSION"] = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        return variables
    }

    /// The app's bundled CLI first (so `cmux` in the mux's shell is this build's), then the
    /// user's tool directories, where acpmux finds agent harnesses such as `sr` (claude-sr),
    /// then the system. Phase A stand-in for the daemon login environment (spec D26, open).
    static func searchPath(home: URL) -> String {
        nonisolated struct Request: Encodable { var bundledBinDirectory: String?; var home: String }
        nonisolated struct Reply: Decodable { var path: String }
        let reply = try? HomeRules.chiefBrain("search_path", Request(bundledBinDirectory: bundledBinPath, home: home.path)) as Reply
        return reply?.path ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// Spawns the host through a throwaway shell with job control, so it gets
    /// its own process group and is adopted by launchd when the shell exits.
    /// The file that hands the mux's conversation token to the host (0600).
    var tokenFile: URL { muxHome.appendingPathComponent("agent-token") }

    /// What `start` did.
    public enum StartOutcome: Equatable, Sendable {
        /// A live host holds the home's lock and its token: no new token.
        case reusedRunningHost(pid: pid_t?)
        /// A token was minted and a host launched (its pid when known).
        case launched(pid: pid_t?)

        /// The process to watch: when it exits, Home starts the host again.
        public var pid: pid_t? {
            switch self {
            case .reusedRunningHost(let pid), .launched(let pid): pid
            }
        }
    }

    /// Starts the host for a Home that opened. `mintToken` replaces the
    /// owner's agent_mux credential and revokes the binding of the host that
    /// runs, so it is called only when the host must start.
    @concurrent public func start(mintToken: @Sendable () async throws -> String) async throws -> StartOutcome {
        // The rules (`chief_brain.host_start_step`) order the start; this runs each effect:
        // cmux NEXT's one-time adoption of its old homes ends before its brain starts (cx-is1kf.9).
        // The app's own acpmux is the app's to start and hand off (its version handoff), never
        // the Chief's: it runs the person's chats too. A host still on the Chief's own daemon (the
        // previous build's after an update) moves over, and that daemon ends (ChiefAppAcpmuxMove);
        // one that cannot move yet hands off when its turn ends, and its exit brings the next start
        // (ChiefBrainWatch). With the kill switch (`CMUX_CHIEF_OWN_ACPMUX=1`) a host this app
        // launched on the app's acpmux moves back to the Chief's own daemon, and a Chief-home
        // acpmux that runs from a replaced bundle, or without this Chief home, is handed off
        // (AcpmuxChiefHandoff): a host that takes it is asked to hand off when idle (SIGUSR1), so an
        // update never cuts a Chief turn; only an older host is stopped. A live host that reads the
        // token file keeps its binding; else a token is minted and a host launched, and on the
        // app's acpmux the host's lock names its pid, so the next start does not take it for an old one.
        let chiefHome = ChiefHome(root: muxHome, isolated: false)
        // Swift's `if usesAppAcpmux, let acpmux` took the app's-acpmux path only with an acpmux; the
        // rules get that, so a missing acpmux takes the leave path as before.
        var state = StartState()
        var event = StartEvent(kind: "begin", usesAppAcpmux: usesAppAcpmux && acpmux != nil, hasAcpmux: acpmux != nil)
        // Every step names one effect; the bound only ends a reply that never finishes.
        for _ in 0..<32 {
            let reply: StartReply = try HomeRules.chiefBrain("host_start_step", StartRequest(state: state, event: event))
            state = reply.state
            guard let effect = reply.effects.last else { break }
            for effect in reply.effects.dropLast() { _ = try await run(effect, chiefHome: chiefHome, mintToken: mintToken) }
            switch try await run(effect, chiefHome: chiefHome, mintToken: mintToken) {
            case .next(let next): event = next
            case .finished(let outcome): return outcome
            }
        }
        throw HomeRulesError(op: "chief_brain.host_start_step", code: .decode, detail: "the start never finished")
    }

    private nonisolated enum StartStep {
        case next(StartEvent)
        case finished(StartOutcome)
    }

    /// Runs one effect of the start; returns the event it gives the rules, or the start's outcome.
    private func run(_ effect: StartEffect, chiefHome: ChiefHome,
                     mintToken: @Sendable () async throws -> String) async throws -> StartStep {
        switch effect.kind {
        case "adoptBuildHomes":
            await AcpmuxEnvironment.adoptBuildHomes()
            return .next(StartEvent(kind: "done"))
        case "ensureAppAcpmux":
            await ensureAppAcpmux?()
            return .next(StartEvent(kind: "done"))
        case "runAppAcpmuxMove":
            guard let acpmux else { return .next(StartEvent(kind: "moved", ok: false)) }
            return .next(StartEvent(kind: "moved", ok: await ChiefAppAcpmuxMove(home: chiefHome, app: acpmux).run()))
        case "leaveAppAcpmux":
            return .next(StartEvent(kind: "moved", ok: await ChiefAppAcpmuxMove.leaveAppAcpmux(home: chiefHome)))
        case "handOffIfStale":
            guard let acpmux else { return .next(StartEvent(kind: "handOff", stale: false)) }
            let stale = await AcpmuxChiefHandoff(environment: acpmux, chiefMuxHome: muxHome.path)
                .handOffIfStale(waitFor: { ChiefHostStop.askToHandOffWhenIdle(home: chiefHome) != nil })
            return .next(StartEvent(kind: "handOff", stale: stale))
        case "stopHost":
            return .next(StartEvent(kind: "stopped", pid: await ChiefHostStop.stop(home: chiefHome)))
        case "waitForExit":
            if let pid = effect.pid {
                _ = await AgentPaneProcessExit(pid: pid).event(within: .seconds(effect.seconds ?? 15))
            }
            return .next(StartEvent(kind: "done"))
        case "checkToken":
            return .next(StartEvent(kind: "token", hasToken: runningHostHasToken))
        case "mintAndLaunch":
            let token = try await mintToken()
            return .next(StartEvent(kind: "launched", pid: await launch(agentToken: token)))
        case "readLock":
            return .next(StartEvent(kind: "lockRead", pid: ChiefHostStop.runningHostPID(home: chiefHome)))
        case "markPid":
            if let acpmux, let pid = effect.pid { ChiefAppAcpmuxMove(home: chiefHome, app: acpmux).mark(pid: pid) }
            return .next(StartEvent(kind: "done"))
        case "finish":
            let pid = effect.outcome?.pid
            return .finished(effect.outcome?.kind == "launched" ? .launched(pid: pid) : .reusedRunningHost(pid: pid))
        default:
            throw HomeRulesError(op: "chief_brain.host_start_step", code: .decode, detail: "unknown effect \(effect.kind)")
        }
    }

    /// `chief_brain.host_start_step`'s state, round-tripped whole.
    private nonisolated struct StartState: Codable {
        nonisolated struct Outcome: Codable {
            var kind: String
            var pid: Int32?
        }
        var phase: String?
        var usesAppAcpmux: Bool?
        var hasAcpmux: Bool?
        var pending: String?
        var launchedPid: Int32?
        var outcome: Outcome?
    }

    private nonisolated struct StartEvent: Encodable {
        var kind: String
        var usesAppAcpmux: Bool?
        var hasAcpmux: Bool?
        var ok: Bool?
        var stale: Bool?
        var pid: Int32?
        var hasToken: Bool?
    }

    private nonisolated struct StartEffect: Decodable {
        var kind: String
        var pid: Int32?
        var seconds: Int?
        var outcome: StartState.Outcome?
    }

    private nonisolated struct StartRequest: Encodable {
        var state: StartState
        var event: StartEvent
    }

    private nonisolated struct StartReply: Decodable {
        var state: StartState
        var effects: [StartEffect]
    }

    /// Whether a host holds this home's lock (`state/host.lock`) and the
    /// token file it reconnects with is there.
    var runningHostHasToken: Bool {
        // concurrency-allow: a small local file read, off the main actor in `start`
        let token = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !token.isEmpty && ChiefMigration.lockHeld(at: muxHome.appendingPathComponent("state/host.lock"))
    }

    @concurrent func launch(agentToken: String) async -> pid_t? {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")
        do {
            try FileManager.default.createDirectory(at: muxHome, withIntermediateDirectories: true)
            // Created 0600 from the start, so the token is never readable by others.
            try? FileManager.default.removeItem(at: tokenFile)
            guard FileManager.default.createFile(atPath: tokenFile.path, contents: Data(agentToken.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                logger.error("mux agent token file could not be written")
                return nil
            }
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = arguments
            shell.environment = childEnvironment
            // LAUNCH-NO-TCC-PROMPTS: the host and what it starts without a
            // folder of its own (its acpmux daemon) run in the Chief home,
            // never the app's folder (`/`) or the home folder, where an
            // agent reads Downloads, Documents and Desktop at once.
            shell.currentDirectoryURL = muxHome
            shell.standardInput = FileHandle.nullDevice
            let output = Pipe()
            shell.standardOutput = output
            shell.standardError = FileHandle.nullDevice
            try shell.run()
            // The shell exits right after the background start; its one line is the pid.
            // concurrency-allow: one pid line from a shell that exits at once, off the main actor in @concurrent `launch`
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let pid = pid_t(printed.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 > 1 ? $0 : nil }
            logger.info("mux host started for \(muxHome.path, privacy: .public) pid \(pid.map(String.init) ?? "?", privacy: .public)")
            return pid
        } catch {
            logger.error("mux host failed to start: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
