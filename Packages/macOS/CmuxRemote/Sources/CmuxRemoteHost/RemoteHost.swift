// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import CmuxRemoteWire
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

    public init?(line: [String: Any]) {
        guard let secret = (line["supervisor_secret"] as? String).flatMap(RemoteWire.unhex), secret.count >= 16 else { return nil }
        supervisorSecret = secret
        daemonBuild = line["daemon_build"] as? String ?? ""
        computerUse = line["computer_use"] as? Bool ?? false
        screenSharing = line["screen_sharing"] as? Bool ?? false
        headless = line["headless"] as? Bool ?? true
        hubURL = line["hub_url"] as? String
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
    let computerUse: ComputerUseWorkers
    private let core: HostCore
    /// How long the host serves with no daemon connected before it exits.
    static let adoptionGrace: TimeInterval = 60
    private var orphanTimer: DispatchSourceTimer?
    private var accessibilityObserver: (any NSObjectProtocol)?

    public init(layout: RemoteHostLayout, bootstrap: HostBootstrap, executable: String, stateDirectory: String, scope: String) {
        self.layout = layout
        let workerEnvironment = Self.workerEnvironment(hubURL: bootstrap.hubURL, headless: bootstrap.headless)
        let launch = WorkerLaunch(executable: executable, environment: workerEnvironment, logPath: layout.log,
                                  stateDirectory: stateDirectory, scope: scope)
        permissions = PermissionAuthority(probe: PermissionAuthority.processProbe(executable: executable, logPath: layout.log))
        let core = HostCore(secret: bootstrap.supervisorSecret, daemonBuild: bootstrap.daemonBuild)
        self.core = core
        screen = ScreenWorkerSupervisor(launch: launch, layout: layout) { core.statusChanged() }
        computerUse = ComputerUseWorkers(launch: launch, layout: layout) { core.statusChanged() }
        super.init()
        core.host = self
        core.config = (bootstrap.computerUse, bootstrap.screenSharing, bootstrap.headless)
    }

    /// The workers' whole environment: nothing from the daemon's (it carries cmux tokens).
    nonisolated static func workerEnvironment(hubURL: String?, headless: Bool) -> [String: String] {
        var environment = [
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_REMOTE_HEADLESS": headless ? "1" : "0",
        ]
        if let hubURL { environment["CMUX_REMOTE_HUB_URL"] = hubURL }
        return environment
    }

    /// Starts serving: both sockets, the first probe, the Screen Sharing worker
    /// when sharing is on, and the Accessibility change observer.
    public func start() throws {
        let supervisor = try LocalSocket.listen(layout.supervisorSocket)
        let app = try LocalSocket.listen(layout.appSocket)
        let core = self.core
        LocalSocket.serve(supervisor, name: "remote-supervisor") { channel in core.serveSupervisor(channel) }
        LocalSocket.serve(app, name: "remote-app") { channel in core.serveApp(channel) }
        Task.detached { await core.refresh() }
        screen.setWanted(core.config.screenSharing)
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
        screen.setWanted(false)
        computerUse.stopAll()
        unlink(layout.supervisorSocket)
        unlink(layout.appSocket)
        exit(0)
    }

    // MARK: Quit & Reopen

    /// macOS asks to quit and reopen cmux Remote after a Screen Recording
    /// grant. The new grant reaches the features through new workers; the host
    /// keeps its daemon link and stays.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.notice("quit requested (Quit & Reopen after a grant): restarting workers instead")
        let core = self.core
        Task.detached { await core.refresh(forceRestart: true) }
        return .terminateCancel
    }
}

/// The host's state and request handling, off the main actor.
final class HostCore: @unchecked Sendable { // crash-allow: mutable fields are read and written under `lock`
    private let lock = NSLock()
    private let secret: Data
    private let daemonBuild: String
    weak var host: RemoteHost?
    private var supervisors: [LineChannel] = []
    private var appGrant: (stamp: ProcessStamp, secret: Data)?
    private var _config = (computerUse: false, screenSharing: false, headless: true)
    private var draining = false
    /// When the current grants were first seen (a worker started before must restart).
    private var grantsChangedAt = Date.distantPast

    init(secret: Data, daemonBuild: String) {
        self.secret = secret
        self.daemonBuild = daemonBuild
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
        let running = host.computerUse.running
        workers[RemoteWorkerKind.computerUse.rawValue] = [
            "state": running.isEmpty ? "idle" : "running",
            "pids": running.keys.sorted().map(Int.init),
            "stale": running.values.contains { $0 < grantsChanged },
        ]
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

    /// Probes the grants. A grant that appeared since a worker started
    /// restarts that worker (now when idle, else after its session); `forceRestart`
    /// restarts idle workers whatever the probe says (Quit & Reopen).
    func refresh(forceRestart: Bool = false) async {
        guard let host else { return }
        let (snapshot, changed) = host.permissions.refresh()
        if changed { lock.withLock { grantsChangedAt = Date() } }
        if changed || forceRestart {
            logger.notice("grants \(snapshot.map { "ax=\($0.accessibility) sr=\($0.screenRecording)" } ?? "unknown", privacy: .public); restarting stale workers")
            host.screen.restart(force: false)
        }
        statusChanged()
    }

    // MARK: Supervisor socket (the daemon)

    func serveSupervisor(_ channel: LineChannel) {
        guard let hello = channel.readObject(), hello["type"] as? String == "hello",
              let given = (hello["secret"] as? String).flatMap(RemoteWire.unhex), RemoteWire.sameSecret(given, secret) else {
            channel.write(RemoteWire.failure(id: nil, code: "refused", message: "bad hello"))
            channel.close()
            return
        }
        let minimum = hello["min"] as? Int ?? 1, maximum = hello["max"] as? Int ?? 1
        guard let version = RemoteWire.negotiate(peerMinimum: minimum, peerMaximum: maximum) else {
            channel.write(RemoteWire.failure(id: nil, code: "protocol", message: "no common protocol (host speaks \(RemoteWire.minimumProtocol)...\(RemoteWire.maximumProtocol))"))
            channel.close()
            return
        }
        lock.withLock { supervisors.append(channel) }
        Task { @MainActor in self.host?.daemonArrived() }
        var hello: [String: Any] = ["type": "hello", "protocol": version]
        for (key, value) in status() { hello[key] = value }
        channel.write(RemoteWire.line(hello))
        logger.notice("daemon connected (protocol \(version, privacy: .public))")
        while let request = channel.readObject() {
            let id = request["id"]
            let method = request["method"] as? String ?? ""
            let params = request["params"] as? [String: Any] ?? [:]
            Task { channel.write(await self.handleSupervisor(id: id, method: method, params: params)) }
        }
        let alone = lock.withLock { () -> Bool in
            supervisors.removeAll { $0 === channel }
            return supervisors.isEmpty
        }
        channel.close()
        logger.notice("daemon disconnected")
        if alone { Task { @MainActor in self.host?.armOrphanTimer() } }
    }

    private func handleSupervisor(id: Any?, method: String, params: [String: Any]) async -> Data {
        guard let host else { return RemoteWire.failure(id: id, code: "gone", message: "the host is stopping") }
        switch method {
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
            case .computerUse: host.computerUse.stopAll()
            case nil: return RemoteWire.failure(id: id, code: "bad_request", message: "worker must be computer-use or screen-sharing")
            }
            return RemoteWire.answer(id: id, result: status())
        case "config":
            var next = config
            if let value = params["computer_use"] as? Bool { next.computerUse = value }
            if let value = params["screen_sharing"] as? Bool { next.screenSharing = value }
            if let value = params["headless"] as? Bool { next.headless = value }
            config = next
            // A new headless choice reaches the worker at its next start (now when idle).
            if host.screen.setEnvironment("CMUX_REMOTE_HEADLESS", next.headless ? "1" : "0") { host.screen.restart(force: false) }
            host.screen.setWanted(next.screenSharing)
            if !next.computerUse { host.computerUse.stopAll() }
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

    // MARK: App socket

    /// The app's connections: a hello with the secret from `app_grant`, from
    /// that exact process; then one `open` that turns the connection into a
    /// channel (Computer Use control, or the Screen Sharing worker's socket).
    func serveApp(_ channel: LineChannel) {
        guard let hello = channel.readObject(), hello["type"] as? String == "hello",
              let given = (hello["secret"] as? String).flatMap(RemoteWire.unhex),
              let grant = lock.withLock({ appGrant }), RemoteWire.sameSecret(given, grant.secret),
              let peer = channel.peer?.stamp, peer == grant.stamp else {
            channel.write(RemoteWire.failure(id: nil, code: "refused", message: "not the cmux app this host was given"))
            channel.close()
            return
        }
        guard let host, let request = channel.readObject() else { return channel.close() }
        let id = request["id"]
        switch request["channel"] as? String {
        case RemoteWorkerKind.computerUse.rawValue:
            guard config.computerUse else {
                channel.write(RemoteWire.failure(id: id, code: "off", message: "Computer Use is off"))
                return channel.close()
            }
            // The tagged DEV app this channel's agents may drive (legacy dogfood scope; only the app opens a channel).
            let prefix = "com.cmuxterm.app.debug."
            let allowed = (request["allowed_target_bundle_id"] as? String).flatMap {
                $0.hasPrefix(prefix) && $0.count > prefix.count && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } ? $0 : nil
            }
            host.computerUse.open(for: channel, id: id, environment: ["CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS": allowed ?? ""])
        case RemoteWorkerKind.screenSharing.rawValue:
            guard let worker = try? LocalSocket.connect(host.layout.screenSharingSocket) else {
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
