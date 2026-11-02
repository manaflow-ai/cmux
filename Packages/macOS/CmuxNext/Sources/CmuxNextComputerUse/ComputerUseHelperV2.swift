// SPDX-License-Identifier: GPL-3.0-or-later
public import Darwin
public import Foundation
import os
import Security
import CmuxNextWakeups

private let helperV2Logger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-v2")

/// The cmux Computer Use helper v2 (`computerUse.driver = "upstream"`).
///
/// The helper app ("cmux Computer Use (dev).app" in DEV builds, bundle id
/// com.cmuxterm.cua.dev) runs upstream Cua Driver in process. This app
/// starts it with responsibility disclaimed (`DisclaimedHelperSpawner`), so
/// macOS checks Accessibility and Screen Recording against the helper and
/// never against cmux. Its stdin is our control pipe: we send the socket
/// path, the per-launch secret and the trusted acpmux cdhash there, and
/// EOF (stop, quit or crash of this app) stops the helper. Machine consent
/// travels only on the host consent socket (``ComputerUseHelperV2HostLink``),
/// where the helper checks this app by audit token.
///
/// The helper socket admits only `acpmux cua-mcp` bridges that descend from
/// an acpmux daemon this app registered (`registerAcpmuxDaemon`). acpmux
/// finds the socket and secret in `endpoint.json` in the private directory
/// named by `endpointDirectoryKey`, which every acpmux daemon this app
/// spawns gets in its environment. Same-uid processes can read that file;
/// the secret is defense in depth, the kernel identity checks are the boundary.
@MainActor
public final class ComputerUseHelperV2 {
    public enum State: Equatable {
        case off
        /// On, but the helper is missing, did not start, or responsibility
        /// could not be disclaimed.
        case unavailable(String)
        case running(pid_t)
    }

    nonisolated static let helperAppName = "cmux Computer Use (dev).app"
    nonisolated static let helperBundleID = "com.cmuxterm.cua.dev"
    nonisolated static let helperExecutableName = "cmux-cua-helper"
    /// The variable that names the endpoint directory for acpmux.
    nonisolated static let endpointDirectoryKey = "CMUX_NEXT_CUA_V2_DIR"
    nonisolated static let endpointFileName = "endpoint.json"
    nonisolated static let socketFileName = "h.sock"
    nonisolated static let hostSocketFileName = "c.sock"

    private(set) var state: State = .off
    public let directory: String
    private let helperApp: @Sendable () -> URL?
    /// The copy outside this app that runs (ComputerUseHelperStaging).
    private let staging: ComputerUseHelperStaging
    /// This app's acpmux (executable and daemon socket), set by the agent
    /// pane source once it resolves acpmux.
    public var acpmux: @Sendable () -> (executable: URL, socketPath: String)?
    /// This app's acpmux daemon's `_acpmux/machine_consent_get` result (nil
    /// on any failure), asked fresh for each of the helper's consent
    /// questions; set with `acpmux`. Unset, every answer is "no answer" and
    /// the helper refuses every call that needs consent.
    public var machineConsent: @Sendable () async -> Data? = { nil }
    /// Records a call the helper refused for consent ("screen" or "control").
    public var consentRefused: @Sendable (String) async -> Void = { _ in }
    private let spawner: any ComputerUseHelperV2Spawning
    private let clock: any Clock<Duration>
    private let readyTimeout: Duration
    private let exitGrace: Duration
    private var child: ComputerUseHelperV2Child?
    /// Logs the helper's control lines after `ready` (``logControlLines(_:pid:)``).
    private var controlLog: Task<Void, Never>?
    /// The helper's host consent connection, while it runs.
    private var hostLink: ComputerUseHelperV2HostLink?
    private var generation = 0
    private let restarts: ComputerUseHelperRestarts
    /// Only explicit setup clicks; never persisted across app launches.
    private var pendingPermissions: Set<String> = []

    init(directory: String = ComputerUseHelperV2.defaultDirectory(),
         helperApp: @escaping @Sendable () -> URL? = { ComputerUseHelperV2.embeddedHelperApp() },
         acpmux: @escaping @Sendable () -> (executable: URL, socketPath: String)? = { nil },
         staging: ComputerUseHelperStaging = .upstream(),
         spawner: any ComputerUseHelperV2Spawning = DisclaimedHelperSpawner(),
         clock: any Clock<Duration> = ContinuousClock(),
         readyTimeout: Duration = .seconds(10),
         exitGrace: Duration = .seconds(2)) {
        self.directory = directory
        self.helperApp = helperApp
        self.acpmux = acpmux
        self.staging = staging
        self.spawner = spawner
        self.clock = clock
        self.readyTimeout = readyTimeout
        self.exitGrace = exitGrace
        self.restarts = ComputerUseHelperRestarts(clock: clock)
    }

    var socketPath: String { directory + "/" + Self.socketFileName }
    var hostSocketPath: String { directory + "/" + Self.hostSocketFileName }
    var endpointPath: String { directory + "/" + Self.endpointFileName }

    /// What every acpmux daemon this app spawns gets: the endpoint directory
    /// (constant for this app build, so a daemon that outlives a helper
    /// restart still finds the current endpoint).
    public nonisolated static func childEnvironment(directory: String) -> [String: String] {
        [endpointDirectoryKey: directory]
    }

    /// The helper's whole environment (nothing is inherited from this app,
    /// whose environment carries cmux tokens). The helper forces the same
    /// Cua Driver values itself before the driver loads.
    nonisolated static func environment(home: String = NSHomeDirectory(),
                                        temporaryDirectory: String = ComputerUseHelperDaemon.userTemporaryDirectory(),
                                        user: String = NSUserName(),
                                        bundleID: String? = Bundle.main.bundleIdentifier) -> [String: String] {
        // Legacy permits an exact tagged DEV bundle for dogfood. Only this
        // app chooses that scope. Do not read it from an agent or inherited env.
        let prefix = "com.cmuxterm.app.debug."
        let allowed = bundleID.flatMap { $0.hasPrefix(prefix) && $0.count > prefix.count ? $0 : nil } ?? ""
        return [
            "CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS": allowed,
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_TELEMETRY_ENABLED": "false",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
            // Upstream waits up to 1000 ms after each input action for a
            // window change, even when the target redraws; 100 ms keeps a 2x
            // margin over the measured 50 ms (134 ms clicks) for a new window
            // or sheet to appear.
            "CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS": "100",
            "CUA_DRIVER_HOST_BUNDLE_ID": helperBundleID,
            "HOME": home,
            "TMPDIR": temporaryDirectory,
            "USER": user,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }

    /// `<this user's temp dir>/cmux-cua-v2/<scope>`: per user, 0700, one
    /// per app build (bundle id), short enough for a socket address.
    nonisolated static func defaultDirectory(bundleID: String = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app") -> String {
        "\(ComputerUseHelperDaemon.userTemporaryDirectory())cmux-cua-v2/\(ComputerUseHelperDaemon.scope(bundleID))"
    }

    /// Whether this build carries the helper v2. DEV builds embed it; a
    /// build without it (NIGHTLY, release today) runs the legacy helper
    /// when `computerUse.driver` is "upstream" (`ComputerUseHelperDaemon.effectiveDriver`).
    public var isInBuild: Bool { helperApp() != nil }

    /// DEV builds embed the dev helper at Contents/Library (scripts/cmux-next/embed-cua-helper-dev.sh).
    nonisolated static func embeddedHelperApp(bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appending(path: "Contents/Library/\(helperAppName)", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.appending(path: "Contents/MacOS/\(helperExecutableName)").path) ? url : nil
    }

    /// Computer Use on with the upstream driver: start the helper (once); otherwise stop it.
    func apply(enabled: Bool) async {
        generation &+= 1
        let current = generation
        guard enabled else { return await stop() }
        if case .running = state { return }
        guard let embedded = helperApp() else { return unavailable("the cmux Computer Use (dev) helper is not in this build") }
        let runningCheck = await staging.runningCheck(for: embedded)
        guard current == generation else { return }
        guard let runningCheck else { return unavailable("the helper code requirement could not be read") }
        // Nested in this app, macOS checks the helper's Screen Recording as this app: run a verified copy outside it.
        let staged = await staging.stage(embedded)
        guard current == generation else { return }
        guard let app = staged else { return unavailable("the helper copy outside the app could not be made or verified") }
        guard ComputerUseHelperDaemon.makePrivateDirectory((directory as NSString).deletingLastPathComponent),
              ComputerUseHelperDaemon.makePrivateDirectory(directory) else {
            return unavailable("\(directory) is not a private directory of this user")
        }
        unlink(endpointPath)
        let executable = app.appending(path: "Contents/MacOS/\(Self.helperExecutableName)")
        let spawned: ComputerUseHelperV2Child
        do {
            spawned = try spawner.spawn(executable: executable, environment: Self.environment(),
                                        logPath: directory + "/helper.log")
        } catch {
            return unavailable("the helper did not start: \(error)")
        }
        let trusted = await staging.acceptsRunningProcess(spawned.pid, check: runningCheck)
        guard current == generation else {
            spawned.closeInput()
            spawner.terminate(spawned.pid)
            return
        }
        guard trusted else {
            spawned.closeInput()
            spawner.terminate(spawned.pid)
            return unavailable("the running helper pid \(spawned.pid) failed its signature check")
        }
        let secret = Self.makeSecret()
        // The host link's own secret: sent only on the helper's stdin, never written to disk.
        let hostSecret = Self.makeSecret()
        let acpmux = self.acpmux()
        await spawned.send(Self.configureLine(socket: socketPath, hostSocket: hostSocketPath, hostSecret: hostSecret,
                                              secret: secret, acpmuxExecutable: acpmux?.executable))
        let readySocket = await Self.readySocket(of: spawned, within: readyTimeout, clock: clock)
        guard current == generation else {
            spawned.closeInput()
            spawner.terminate(spawned.pid)
            return
        }
        guard readySocket == socketPath else {
            spawned.closeInput()
            spawner.terminate(spawned.pid)
            return unavailable("the helper did not report ready")
        }
        let link = await ComputerUseHelperV2HostLink.connect(path: hostSocketPath, helperPID: spawned.pid,
                                                             executable: executable, secret: hostSecret)
        guard current == generation else {
            link?.close()
            spawned.closeInput()
            spawner.terminate(spawned.pid)
            return
        }
        if link == nil {
            helperV2Logger.error("cmux Computer Use helper v2 consent link failed; the helper refuses every call that needs consent")
        }
        hostLink = link
        child = spawned
        state = .running(spawned.pid)
        restarts.watch(spawner.watchExit(of: spawned.pid) { [weak self, pid = spawned.pid] in self?.helperExited(pid) })
        helperV2Logger.notice("cmux Computer Use helper v2 ready pid=\(spawned.pid, privacy: .public) socket=\(readySocket ?? "", privacy: .public)")
        controlLog?.cancel()
        let lines = spawned.lines
        let pid = spawned.pid
        // Read per question, so wiring set after this start still answers.
        let consent: @Sendable () async -> Data? = { [weak self] in
            guard let query = await MainActor.run(body: { self?.machineConsent }) else { return nil }
            return await query()
        }
        let refused: @Sendable (String) async -> Void = { [weak self] surface in
            guard let record = await MainActor.run(body: { self?.consentRefused }) else { return }
            await record(surface)
        }
        // task-owner: stored in controlLog, cancelled by stop() and terminateForQuit(); it ends at the helper's EOF.
        controlLog = Task.detached {
            async let control: Void = Self.logControlLines(lines, pid: pid)
            if let link { await ComputerUseHelperV2Consent.serve(link, pid: pid, consent: consent, refused: refused) }
            await control
        }
        guard await Self.writeEndpoint(path: endpointPath, socket: socketPath, secret: secret, owner: spawned.pid) else {
            await stop()
            return unavailable("cannot write \(endpointPath)")
        }
        let permissions = pendingPermissions
        pendingPermissions.removeAll()
        for permission in permissions {
            await sendPermission(permission)
        }
        helperV2Logger.notice("cmux Computer Use helper v2 started pid=\(spawned.pid, privacy: .public)")
        // An acpmux daemon that already runs (it outlives the app) is registered now.
        if let acpmux { await registerAcpmuxDaemon(acpmuxSocket: acpmux.socketPath) }
    }

    /// Registers the acpmux daemon listening on `acpmuxSocket`, after checking
    /// it runs this app's acpmux executable. Its descendants (agent MCP
    /// bridges) may then use the helper.
    public func registerAcpmuxDaemon(acpmuxSocket: String) async {
        guard let child, let executable = acpmux()?.executable,
              let stamp = await Self.daemonStamp(socketPath: acpmuxSocket, executable: executable) else { return }
        await child.send(Self.registerLine(stamp))
    }

    /// A person's permission button in Computer Use setup. Startup and agent
    /// tool calls never use this private host channel to request grants.
    public func requestPermission(screenRecording: Bool) async {
        let permission = screenRecording ? "screen_recording" : "accessibility"
        switch state {
        case .off: pendingPermissions.insert(permission)
        case .running: await sendPermission(permission)
        case .unavailable: break
        }
    }

    private func sendPermission(_ permission: String) async {
        guard case .running = state, let child else { return }
        await child.send(Self.line(["type": "request_permission",
                                   "permission": permission]))
    }

    /// Stops the helper: close its stdin (it exits on EOF), then SIGTERM this
    /// exact pid if it is still alive after `exitGrace`.
    func stop() async {
        restarts.stopped()
        pendingPermissions.removeAll()
        unlink(endpointPath)
        guard let child else {
            state = .off
            return
        }
        self.child = nil
        state = .off
        controlLog?.cancel()
        controlLog = nil
        hostLink?.close()
        hostLink = nil
        child.closeInput()
        let spawner = self.spawner
        // wakeup-allow: one bounded grace before SIGTERM when the helper is stopped.
        try? await clock.sleep(for: exitGrace)
        if kill(child.pid, 0) == 0 { spawner.terminate(child.pid) }
    }

    /// App quit: close the helper's stdin now (it exits on EOF; the kernel
    /// closes the pipe anyway if this app dies).
    func terminateForQuit() {
        pendingPermissions.removeAll()
        generation &+= 1
        restarts.stopped()
        unlink(endpointPath)
        controlLog?.cancel()
        controlLog = nil
        hostLink?.close()
        hostLink = nil
        child?.closeInput()
        child = nil
        state = .off
    }

    /// The helper exited and this app did not stop it (macOS "Quit & Reopen"
    /// after a privacy grant, a crash): it is reaped and its endpoint goes, so
    /// acpmux finds no dead socket, then it starts again within the budget.
    private func helperExited(_ pid: pid_t) {
        guard case .running(let running) = state, running == pid, let child, child.pid == pid else { return }
        self.child = nil
        controlLog?.cancel()
        controlLog = nil
        hostLink?.close()
        hostLink = nil
        unlink(endpointPath)
        child.closeInput()
        // The exited child stays a zombie until reaped; a SIGTERM to it does nothing.
        spawner.terminate(pid)
        guard restarts.takeRestart() else { return unavailable("the helper exited again within a minute") }
        helperV2Logger.notice("cmux Computer Use helper v2 pid=\(pid, privacy: .public) exited; starting it again")
        state = .off
        let expected = generation
        // task-owner: one start; a later apply or quit moves `generation`, and then it does nothing.
        Task { [weak self] in
            guard let self, generation == expected else { return }
            await apply(enabled: true)
        }
    }

    private func unavailable(_ reason: String) {
        pendingPermissions.removeAll()
        helperV2Logger.error("cmux Computer Use helper v2 unavailable: \(reason, privacy: .public)")
        state = .unavailable(reason)
    }

    // MARK: - Helpers

    nonisolated static func line(_ fields: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Logs each control line the helper writes after `ready` (the
    /// `register_acpmux` acks and control errors; tool `result` lines are
    /// skipped), so a live check reads them from the unified log
    /// (scripts/cmux-next/cua-helper-v2-live.py). The lines carry no secret.
    /// `handled` takes the lines it answers (machine consent) first.
    nonisolated static func logControlLines(_ lines: AsyncStream<Data>, pid: pid_t,
                                            handled: @Sendable ([String: Any]) -> Bool = { _ in false }) async {
        // Its own Logger: the file-level one is main-actor isolated.
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-v2")
        for await line in lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = object["type"] as? String, type != "result", !handled(object) else { continue }
            let text = String(decoding: line.prefix(512), as: UTF8.self)
            logger.notice("cmux Computer Use helper v2 control pid=\(pid, privacy: .public) \(text, privacy: .public)")
        }
    }

    /// The `socket` of the helper's first `ready` line, or nil after `within`.
    nonisolated static func readySocket(of child: ComputerUseHelperV2Child, within: Duration,
                                        clock: any Clock<Duration>) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await line in child.lines {
                    if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                       object["type"] as? String == "ready" { return object["socket"] as? String }
                }
                return nil
            }
            group.addTask {
                // wakeup-allow: one bounded ready deadline per helper start, cancelled as soon as the helper answers.
                try? await clock.sleep(for: within)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
