// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import CmuxRemoteWire
import CmuxDeviceHub
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "host")

/// What the daemon hands the host at start, on the bootstrap pipe (fd 3): one
/// JSON line, never argv or env.
public struct HostBootstrap: Sendable {
    public var supervisorSecret: Data
    /// The daemon's build, for status only.
    public var daemonBuild: String
    public var computerUse: Bool
    public var screenSharing: Bool
    /// `remote.headless`: the Screen Sharing worker keeps serving with the app quit.
    public var headless: Bool
    /// The device hub the Screen Sharing worker joins.
    public var hubURL: String?
    /// The daemon's own socket: a supervisor is admitted only when it is the process serving it.
    public var daemonSocket: String?

    public init?(line: [String: Any]) {
        guard let secret = (line["supervisor_secret"] as? String).flatMap(RemoteWire.unhex), secret.count >= 16 else { return nil }
        supervisorSecret = secret
        daemonBuild = line["daemon_build"] as? String ?? ""
        computerUse = line["computer_use"] as? Bool ?? false
        screenSharing = line["screen_sharing"] as? Bool ?? false
        headless = line["headless"] as? Bool ?? true
        hubURL = line["hub_url"] as? String
        daemonSocket = (line["daemon_socket"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
}

/// The cmux Remote host process (docs/cmux-remote.md): the daemon's
/// supervisor socket, the app's socket, the grants and the two workers.
@MainActor
public final class RemoteHost: NSObject, NSApplicationDelegate {
    public nonisolated static let build: String = {
        let info = Bundle.main.infoDictionary
        return [info?["CFBundleVersion"] as? String, info?["CmuxRemoteSourceTree"] as? String]
            .compactMap { $0 }.joined(separator: "+")
    }()

    let layout: RemoteHostLayout
    let permissions: PermissionAuthority
    let screen: ScreenWorkerSupervisor
    let computerUse: ComputerUseSupervisor
    let children: RemoteChildLifetime
    let captureLease: RemoteCaptureLease
    private let core: HostCore
    /// How long the host serves with no daemon connected before it exits.
    static let adoptionGrace: TimeInterval = 60
    private var orphanTimer: DispatchSourceTimer?
    private var accessibilityObserver: (any NSObjectProtocol)?
    private var shuttingDown = false

    public init(layout: RemoteHostLayout, bootstrap: HostBootstrap, executable: String, stateDirectory: String, scope: String) {
        self.layout = layout
        let children = RemoteChildLifetime()
        self.children = children
        let namespace = DeviceCaptureNamespace(bundleIdentifier: (Bundle.main.bundleIdentifier ?? "com.cmuxterm.remote.dev") + "." + scope)
        captureLease = RemoteCaptureLease(stateDirectory: stateDirectory,
                                         keychainScope: (Bundle.main.bundleIdentifier ?? "com.cmuxterm.remote.dev") + "." + scope,
                                         home: ProcessInfo.processInfo.environment["HOME"] ?? "",
                                         empty: { try namespace.isEmpty() }, remove: { try namespace.remove() })
        let workerEnvironment = Self.workerEnvironment(hubURL: bootstrap.hubURL, headless: bootstrap.headless,
                                                       home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        let launch = WorkerLaunch(executable: executable, environment: workerEnvironment, logPath: layout.log,
                                  stateDirectory: stateDirectory, scope: scope, lifetime: children)
        let permissions = PermissionAuthority(probe: PermissionAuthority.processProbe(executable: executable, logPath: layout.log, lifetime: children))
        self.permissions = permissions
        let core = HostCore(secret: bootstrap.supervisorSecret, daemonBuild: bootstrap.daemonBuild, daemonSocket: bootstrap.daemonSocket)
        self.core = core
        screen = ScreenWorkerSupervisor(launch: launch, layout: layout) { core.statusChanged() }
        computerUse = ComputerUseSupervisor(launch: launch, layout: layout, onChange: { core.statusChanged() },
                                            requestPermission: { permission in
                                                // The worker's engine asked: macOS names cmux Remote in its prompt.
                                                // The probe spawns a process: off the main thread, then the prompt on it.
                                                Task.detached {
                                                    _ = permissions.refresh()
                                                    _ = await MainActor.run { permissions.request(permission) }
                                                }
                                            })
        super.init()
        core.host = self
        core.config = (bootstrap.computerUse, bootstrap.screenSharing, bootstrap.headless)
    }

    /// The workers' whole environment: nothing from the daemon's (it carries cmux tokens).
    nonisolated static func workerEnvironment(hubURL: String?, headless: Bool, home: String) -> [String: String] {
        var environment = [
            "HOME": home,
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_REMOTE_HEADLESS": headless ? "1" : "0",
        ]
        if let hubURL { environment["CMUX_REMOTE_HUB_URL"] = hubURL }
        return environment
    }

    /// Starts serving: both sockets, the first probe, the Screen Sharing worker
    /// when sharing is on (the Computer Use worker waits for the app's policy), and the
    /// Accessibility change observer.
    public func start() throws {
        let supervisor = try LocalSocket.listen(layout.supervisorSocket)
        let app = try LocalSocket.listen(layout.appSocket)
        let core = self.core
        LocalSocket.serve(supervisor, name: "remote-supervisor") { channel in core.serveSupervisor(channel) }
        LocalSocket.serve(app, name: "remote-app") { channel in core.serveApp(channel) }
        Task.detached { await core.refresh() }
        screen.setWanted(core.config.screenSharing)
        computerUse.setWanted(core.config.computerUse)
        // macOS posts this when the Accessibility list changes: a grant reaches the feature without a poll.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
            Task.detached { await core.refresh() }
        }
        armOrphanTimer()
        logger.notice("cmux Remote host ready pid=\(getpid(), privacy: .public) build=\(Self.build, privacy: .public)")
    }

    // MARK: Daemon presence

    /// No daemon connected: exit after the adoption grace unless one connects.
    func armOrphanTimer() {
        orphanTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // A one-shot deadline, cancelled when a daemon connects.
        timer.schedule(deadline: .now() + Self.adoptionGrace)
        timer.setEventHandler { [weak self] in
            guard let self, !core.daemonConnected else { return }
            logger.notice("no daemon adopted this host within \(Int(Self.adoptionGrace), privacy: .public) s; exiting")
            shutDown()
        }
        timer.resume()
        orphanTimer = timer
    }

    func daemonArrived() {
        orphanTimer?.cancel()
        orphanTimer = nil
    }

    func shutDown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        children.freeze()
        screen.setWanted(false)
        computerUse.stopAll()
        let children = self.children, layout = self.layout
        // task-owner: one bounded shutdown per host. A child that outlives SIGTERM by 15 s gets
        // SIGKILL; the host then exits either way, so frozen admission never outlives it.
        // The daemon's own group-absence check still holds capture closed for any survivor.
        Task.detached {
            if !(await children.terminate(grace: .seconds(15), kill: .seconds(5))) {
                logger.error("remote children were not reaped after SIGKILL; exiting anyway")
            }
            unlink(layout.supervisorSocket)
            unlink(layout.appSocket)
            unlink(layout.computerUseSocket)
            exit(0)
        }
    }

    // MARK: Quit

    /// System Settings' "Quit & Reopen" after a Screen Recording grant: the
    /// new grant reaches the features through new workers, and the host keeps
    /// its daemon link and stays. Any other quit (Activity Monitor, `quit app`,
    /// logout) is the person's: the daemon hears it, so it does not start the
    /// host again on its own, and the host ends its workers and exits.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let quitter = Self.quitSenderBundleID()
        if Self.isQuitAndReopen(senderBundleID: quitter) {
            logger.notice("quit requested (Quit & Reopen after a grant): restarting workers instead")
            let core = self.core
            Task.detached { await core.refresh(forceRestart: true) }
            return .terminateCancel
        }
        logger.notice("quit requested by \(quitter ?? "unknown", privacy: .public): stopping")
        core.announceQuit()
        shutDown()
        // shutDown exits once the workers are reaped; logout waits for that exit.
        return .terminateLater
    }

    /// The bundle id of the process that sent the quit Apple event, if any.
    static func quitSenderBundleID() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Whether a quit is System Settings' Quit & Reopen after a privacy grant.
    nonisolated static func isQuitAndReopen(senderBundleID: String?) -> Bool {
        senderBundleID == "com.apple.systempreferences" || senderBundleID == "com.apple.Settings"
    }
}

/// The host's state and request handling, off the main actor.
final class HostCore: @unchecked Sendable { // crash-allow: mutable fields are read and written under `lock`
    private let lock = NSLock()
    private let secret: Data
    private let daemonBuild: String
    private let daemonSocket: String?
    weak var host: RemoteHost?
    private var supervisors: [LineChannel] = []
    private var appGrant: (stamp: ProcessStamp, secret: Data)?
    private var _config = (computerUse: false, screenSharing: false, headless: true)
    private var draining = false
    private var captureInFlight = false
    /// When the current grants were first seen (a worker started before must restart).
    private var grantsChangedAt = Date.distantPast

    init(secret: Data, daemonBuild: String, daemonSocket: String?) {
        self.secret = secret
        self.daemonBuild = daemonBuild
        self.daemonSocket = daemonSocket
    }

    /// Whether `channel`'s peer is the cmux-tui daemon: the process serving the daemon socket the
    /// host was started for. The secret alone is not enough (the record that keeps it for the
    /// next daemon is readable by every process of this user).
    private func isDaemon(_ channel: LineChannel) -> Bool {
        guard let daemonSocket, let peer = channel.peer?.pid else { return false }
        return LocalSocket.listenerPID(daemonSocket) == peer
    }

    var config: (computerUse: Bool, screenSharing: Bool, headless: Bool) {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    var daemonConnected: Bool { lock.withLock { !supervisors.isEmpty } }

    // MARK: Status

    func status() -> [String: Any] {
        guard let host else { return [:] }
        let snapshot = host.permissions.last
        let screen = host.screen
        let grantsChanged = lock.withLock { grantsChangedAt }
        var workers: [String: Any] = [:]
        var screenWorker: [String: Any] = ["state": screen.pid == nil ? (config.screenSharing ? "starting" : "off") : "running",
                                           "restarts": screen.restarts]
        if let pid = screen.pid { screenWorker["pid"] = Int(pid) }
        if let started = screen.startedAt { screenWorker["stale"] = started < grantsChanged }
        workers[RemoteWorkerKind.screenSharing.rawValue] = screenWorker
        workers[RemoteWorkerKind.computerUse.rawValue] = host.computerUse.statusFields(grantsChangedAt: grantsChanged)
        var result: [String: Any] = [
            "protocol": RemoteWire.maximumProtocol, "build": RemoteHost.build, "pid": Int(getpid()),
            "bundle_id": Bundle.main.bundleIdentifier ?? "", "name": Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "",
            "busy": screen.busy, "workers": workers,
            "config": ["computer_use": config.computerUse, "screen_sharing": config.screenSharing, "headless": config.headless],
        ]
        if let snapshot { result["permissions"] = snapshot.fields }
        if let shared = screen.status { result["screen"] = shared }
        return result
    }

    func statusChanged() {
        let line = RemoteWire.event("status", ["status": status()])
        let channels = lock.withLock { supervisors }
        for channel in channels { channel.write(line) }
        if lock.withLock({ draining }), host?.screen.busy == false {
            Task { @MainActor in self.host?.shutDown() }
        }
    }

    /// The person quit cmux Remote: tells the daemon before the host exits.
    func announceQuit() {
        let line = RemoteWire.event("quit")
        let channels = lock.withLock { supervisors }
        for channel in channels { channel.write(line) }
    }

    /// Probes the grants. A grant that appeared since a worker started
    /// restarts that worker (now when idle, else after its session); `forceRestart`
    /// restarts idle workers whatever the probe says (Quit & Reopen).
    func refresh(forceRestart: Bool = false) async {
        guard let host, host.children.accepting else { return }
        let (snapshot, changed) = host.permissions.refresh()
        if changed { lock.withLock { grantsChangedAt = Date() } }
        if changed || forceRestart {
            logger.notice("grants \(snapshot.map { "ax=\($0.accessibility) sr=\($0.screenRecording)" } ?? "unknown", privacy: .public); restarting stale workers")
            host.screen.restart(force: false)
            // A process that ran before a grant can keep the old Screen Recording answer: a new
            // Computer Use worker reads the new one. Its sessions and grants live in its state
            // directory, and calls carry call_id, so agents lose nothing.
            host.computerUse.restart()
        }
        statusChanged()
    }

    // MARK: Supervisor socket (the daemon)

    func serveSupervisor(_ channel: LineChannel) {
        // A silent peer never holds this thread: the hello has 5 s.
        channel.setReadTimeout(5)
        guard let hello = channel.readObject(), hello["type"] as? String == "hello",
              let given = (hello["secret"] as? String).flatMap(RemoteWire.unhex), RemoteWire.sameSecret(given, secret),
              isDaemon(channel) else {
            channel.write(RemoteWire.failure(id: nil, code: "refused", message: "bad hello"))
            channel.close()
            return
        }
        channel.setReadTimeout(0)
        let minimum = hello["min"] as? Int ?? 1, maximum = hello["max"] as? Int ?? 1
        guard let version = RemoteWire.negotiate(peerMinimum: minimum, peerMaximum: maximum) else {
            channel.write(RemoteWire.failure(id: nil, code: "protocol", message: "no common protocol (host speaks \(RemoteWire.minimumProtocol)...\(RemoteWire.maximumProtocol))"))
            channel.close()
            return
        }
        // One daemon at a time: a handoff's new daemon replaces the old one's connection.
        let replaced = lock.withLock { () -> [LineChannel] in
            defer { supervisors = [channel] }
            return supervisors
        }
        for old in replaced { old.close() }
        Task { @MainActor in self.host?.daemonArrived() }
        var reply: [String: Any] = ["type": "hello", "protocol": version]
        for (key, value) in status() { reply[key] = value }
        channel.write(RemoteWire.line(reply))
        logger.notice("daemon connected (protocol \(version, privacy: .public))")
        while let request = channel.readObject() {
            let id = request["id"]
            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]
            let request = SupervisorRequest(id: id, method: method, params: params)
            Task { [self] in channel.write(await handleSupervisor(request)) }
        }
        let alone = lock.withLock { () -> Bool in
            supervisors.removeAll { $0 === channel }
            return supervisors.isEmpty
        }
        channel.close()
        logger.notice("daemon disconnected")
        if alone { Task { @MainActor in self.host?.armOrphanTimer() } }
    }

    private func handleSupervisor(_ request: SupervisorRequest) async -> Data {
        let (id, method, params) = (request.id, request.method, request.params)
        guard let host else { return RemoteWire.failure(id: id, code: "gone", message: "the host is stopping") }
        switch method {
        case "capture.prepare", "capture.cleanup", "capture.cleanup.unprepared":
            return await capture(request, host: host)
        case "status":
            return RemoteWire.answer(id: id, result: status())
        case "refresh":
            await refresh()
            return RemoteWire.answer(id: id, result: status())
        case "request":
            guard let permission = (params["permission"] as? String).flatMap(RemotePermission.init(rawValue:)) else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "permission must be accessibility or screen-recording")
            }
            _ = host.permissions.refresh()
            let outcome = await MainActor.run { host.permissions.request(permission) }
            return RemoteWire.answer(id: id, result: ["outcome": outcome.rawValue])
        case "open_settings":
            guard let permission = (params["permission"] as? String).flatMap(RemotePermission.init(rawValue:)) else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "permission must be accessibility or screen-recording")
            }
            await MainActor.run { host.permissions.openSettings(permission) }
            return RemoteWire.answer(id: id, result: [:])
        case "restart":
            switch (params["worker"] as? String).flatMap(RemoteWorkerKind.init(rawValue:)) {
            case .screenSharing: host.screen.restart(force: params["force"] as? Bool ?? false)
            case .computerUse: host.computerUse.restart()
            case nil: return RemoteWire.failure(id: id, code: "bad_request", message: "worker must be computer-use or screen-sharing")
            }
            return RemoteWire.answer(id: id, result: status())
        case "config":
            guard host.children.accepting else { return RemoteWire.failure(id: id, code: "capture_quiescing", message: "remote worker admission is closed") }
            var next = config
            if let value = params["computer_use"] as? Bool { next.computerUse = value }
            if let value = params["screen_sharing"] as? Bool { next.screenSharing = value }
            if let value = params["headless"] as? Bool { next.headless = value }
            config = next
            // A new headless choice reaches the worker at its next start (now when idle).
            if host.screen.setEnvironment("CMUX_REMOTE_HEADLESS", next.headless ? "1" : "0") { host.screen.restart(force: false) }
            host.screen.setWanted(next.screenSharing)
            host.computerUse.setWanted(next.computerUse)
            statusChanged()
            return RemoteWire.answer(id: id, result: status())
        case "app_grant":
            guard let stamp = (params["app"] as? [String: Any]).flatMap(ProcessStamp.init(fields:)), stamp.isAlive else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "app must be a live process stamp")
            }
            let fresh = RemoteWire.makeSecret()
            lock.withLock { appGrant = (stamp, fresh) }
            return RemoteWire.answer(id: id, result: ["socket": host.layout.appSocket, "secret": RemoteWire.hex(fresh),
                                                      "host_pid": Int(getpid())])
        case "computer_use.endpoint":
            // The daemon's `computer-use-endpoint`: acpmux never reads files. A starting worker gets a few
            // seconds (this request's own task waits, never the main thread).
            let supervisor = host.computerUse
            let wait = min(Double((params["wait_ms"] as? Int) ?? 5000), 30000) / 1000
            let endpoint = await Task.detached { WorkerReply(supervisor.endpoint(wait: wait)) }.value
            return RemoteWire.answer(id: id, result: endpoint.value)
        case "computer_use.config":
            // The verified app's policy (the daemon forwards only its requests).
            guard let policy = params["config"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]) else {
                return RemoteWire.failure(id: id, code: "bad_request", message: "computer_use.config needs config (a PolicyConfig object)")
            }
            host.computerUse.configure(policy: data, motion: (params["motion"] ?? policy["cursorMotion"]) as? [String: Any],
                                       machine: params["machine"] as? String, computerUse: config.computerUse)
            statusChanged()
            return RemoteWire.answer(id: id, result: status())
        case "computer_use.approvals":
            // Saved approvals: list, forget, always, never, revoke_sessions (the verified app only, through the daemon).
            guard let action = params["action"] as? String,
                  ["list", "forget", "always", "never", "revoke_sessions"].contains(action) else {
                return RemoteWire.failure(id: id, code: "bad_request",
                                          message: "computer_use.approvals needs action list, forget, always, never or revoke_sessions")
            }
            var line: [String: Any] = ["type": "approvals", "action": action]
            if let app = params["app_id"] as? String { line["app_id"] = app }
            var reply = await host.computerUse.request(line)
            // `list`: the saved approvals and the questions waiting (the panel asks on this Mac, so none wait here).
            if action == "list", reply["ok"] as? Bool == true {
                reply["result"] = ["saved": reply["result"] ?? [String: Any](), "pending": [Any]()]
            }
            reply["id"] = id ?? NSNull()
            return RemoteWire.line(reply)
        case "computer_use.session":
            // The person's menu bar, through the daemon (Stop and Show Cursor from any local
            // connection; Resume from the verified app only, checked there).
            guard let line = Self.computerUseSessionLine(params) else {
                return RemoteWire.failure(id: id, code: "bad_request",
                                          message: "computer_use.session needs a session and action stop, resume, spotlight or raise_window")
            }
            var reply = await host.computerUse.request(line)
            reply["id"] = id ?? NSNull()
            return RemoteWire.line(reply)
        case "drain":
            lock.withLock { draining = true }
            statusChanged()
            return RemoteWire.answer(id: id, result: ["busy": host.screen.busy])
        default:
            if method.hasPrefix("screen.") {
                let answer = await host.screen.request(String(method.dropFirst("screen.".count)), params)
                var reply = answer
                reply["id"] = id ?? NSNull()
                return RemoteWire.line(reply)
            }
            return RemoteWire.failure(id: id, code: "unknown_method", message: "unknown method \(method)")
        }
    }

    /// The worker's control line for a `computer_use.session` request, nil when it is malformed.
    static func computerUseSessionLine(_ params: [String: Any]) -> [String: Any]? {
        guard let session = params["session"] as? String, !session.isEmpty, session.utf8.count <= 256 else { return nil }
        switch params["action"] as? String {
        case let action? where action == "stop" || action == "resume":
            var line: [String: Any] = ["type": "session", "action": action, "session": session]
            if let label = params["label"] as? String { line["label"] = String(label.prefix(80)) }
            return line
        case "spotlight": return ["type": "cursor/spotlight", "session": session]
        case "raise_window": return ["type": "window/raise", "session": session]
        default: return nil
        }
    }

    // MARK: App socket

    private func capture(_ request: SupervisorRequest, host: RemoteHost) async -> Data {
        let (id, method) = (request.id, request.method)
        guard lock.withLock({
            guard !captureInFlight else { return false }
            captureInFlight = true
            return true
        }) else { return RemoteWire.answer(id: id, result: CaptureLeaseResult(code: "remote_capture_busy").fields) }
        defer { lock.withLock { captureInFlight = false } }
        guard let binding = CaptureLeaseBinding(fields: request.params),
              let grant = lock.withLock({ appGrant }), grant.stamp.isAlive else {
            return RemoteWire.answer(id: id, result: CaptureLeaseResult(code: "remote_invalid_binding").fields)
        }
        let bundle = await MainActor.run { NSRunningApplication(processIdentifier: grant.stamp.pid)?.bundleIdentifier }
        guard bundle == binding.bundleID, grant.stamp.isAlive else {
            return RemoteWire.answer(id: id, result: CaptureLeaseResult(code: "remote_app_mismatch").fields)
        }
        let result: CaptureLeaseResult
        if method == "capture.prepare" {
            result = await host.captureLease.prepare(binding, children: host.children,
                                                    workerAbsent: host.screen.pid == nil && host.computerUse.pid == nil)
        } else if method == "capture.cleanup.unprepared" {
            let (screen, computerUse) = (host.screen, host.computerUse)
            result = await host.captureLease.cleanupUnprepared(binding, children: host.children,
                                                               stopWorkers: { screen.setWanted(false); computerUse.stopAll() })
        } else {
            guard await host.captureLease.beginCleanup(binding) else {
                return RemoteWire.answer(id: id, result: CaptureLeaseResult(code: "remote_lease_mismatch").fields)
            }
            host.children.freeze()
            host.screen.setWanted(false)
            host.computerUse.stopAll()
            host.children.stopOwnedChildren()
            let exited = await host.children.waitUntilEmpty(timeout: .seconds(15))
            result = await host.captureLease.cleanup(binding, writersExited: exited)
        }
        var fields = result.fields
        // Internal RPC metadata only. The app checks this against its granted host and waits for its exit.
        if let stamp = ProcessStamp.of(getpid()) { fields["host_stamp"] = stamp.fields }
        return RemoteWire.answer(id: id, result: fields)
    }

    /// The app's connections: a hello with the secret from `app_grant`, from
    /// that exact process; then one `open` that turns the connection into a
    /// channel (the Screen Sharing worker's socket).
    func serveApp(_ channel: LineChannel) {
        channel.setReadTimeout(5)
        guard let hello = channel.readObject(), hello["type"] as? String == "hello",
              let given = (hello["secret"] as? String).flatMap(RemoteWire.unhex),
              let grant = lock.withLock({ appGrant }), RemoteWire.sameSecret(given, grant.secret),
              let peer = channel.peer?.stamp, peer == grant.stamp else {
            channel.write(RemoteWire.failure(id: nil, code: "refused", message: "not the cmux app this host was given"))
            channel.close()
            return
        }
        guard let host, host.children.accepting, let request = channel.readObject() else { return channel.close() }
        // The channel's reads (the pumps) wait as long as the app keeps it open.
        channel.setReadTimeout(0)
        let id = request["id"]
        switch request["channel"] as? String {
        case RemoteWorkerKind.computerUse.rawValue:
            // Computer Use is no app channel any more: the worker serves agents on its own socket,
            // which the daemon hands to acpmux (`computer_use.endpoint`).
            channel.write(RemoteWire.failure(id: id, code: "bad_request",
                                             message: "Computer Use has no app channel; the daemon serves computer-use-endpoint"))
            channel.close()
        case RemoteWorkerKind.screenSharing.rawValue:
            // A worker that is starting answers within seconds; this connection's own thread waits for it.
            guard host.screen.waitReady(until: Date().addingTimeInterval(10)),
                  let worker = try? LocalSocket.connect(host.layout.screenSharingSocket) else {
                channel.write(RemoteWire.failure(id: id, code: "worker_unavailable", message: "the Screen Sharing worker is not running"))
                return channel.close()
            }
            channel.write(RemoteWire.answer(id: id, result: ["pid": host.screen.pid.map(Int.init) ?? 0]))
            let early = channel.takeBuffered()
            BytePump.splice(channel.readDescriptor, worker, prefixForSecond: early, name: "remote-app-screen") {
                close(worker)
                channel.close()
            }
        default:
            channel.write(RemoteWire.failure(id: id, code: "bad_request", message: "channel must be computer-use or screen-sharing"))
            channel.close()
        }
    }
}

/// One supervisor request, handed from the connection's reader thread to the task that answers it.
struct SupervisorRequest: @unchecked Sendable { // crash-allow: built by the reader thread, then read only by the one answering task
    let id: Any?
    let method: String
    let params: [String: Any]
}
