// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "computer-use")

/// The Computer Use worker: one long-lived process while Computer Use is on (`config`
/// `computer_use` and a policy whose mode is not "off"). Its stdin and stdout are the control
/// lines of the worker contract: this host sends `configure` (the policy, the agent socket, a
/// fresh per-launch secret, the state directory and the machine name) and later `config` and
/// `approvals`; the worker answers `ready` once its socket listens. The engine keeps sessions
/// and grants in the state directory, so a restart loses nothing. A crash restarts it after
/// `RestartBackoff`; the daemon learns the new socket and secret from `endpoint()`.
final class ComputerUseSupervisor: Sendable {
    let launch: WorkerLaunch
    let layout: RemoteHostLayout
    /// Called (any thread) when the worker's state changes.
    let onChange: @Sendable () -> Void
    /// Asks macOS for a grant the worker needs (the host's PermissionAuthority; the prompt names cmux Remote).
    let requestPermission: @Sendable (RemotePermission) -> Void

    enum Phase: String, Sendable {
        case off, starting, ready, unavailable
    }

    struct Endpoint: Sendable, Equatable {
        var socket: String
        var secret: String
        var pid: pid_t
    }

    private struct State: @unchecked Sendable { // crash-allow: every field is read and written under the lock
        /// The daemon's `computer_use` switch.
        var switchOn = false
        /// The app sent its policy (`computer_use.config`): no worker runs on a guessed policy.
        var policyKnown = false
        /// Switch on, policy known and not off.
        var wanted = false
        var phase = Phase.off
        var reason: String?
        var child: ChildProcess?
        var channel: LineChannel?
        var endpoint: Endpoint?
        var startedAt: Date?
        /// The latest PolicyConfig JSON and cursor motion the app sent (`computer_use.config`).
        var policy = Data("{}".utf8)
        var motion: [String: Any] = ["enabled": true, "speed": 1.0]
        var machine = ProcessInfo.processInfo.hostName
        var pending: [Int: CheckedContinuation<WorkerReply, Never>] = [:]
        var nextID = 1
        var backoff = RestartBackoff()
        var restarts = 0
        var startAfterExit = false
        var generation = 0
        /// What the worker's agent sessions do now (its `activity` lines), by session.
        var activity = ComputerUseActivity()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Broadcast when the worker reports ready or unavailable, or stops.
    private let readyCondition = NSCondition()

    init(launch: WorkerLaunch, layout: RemoteHostLayout, onChange: @escaping @Sendable () -> Void,
         requestPermission: @escaping @Sendable (RemotePermission) -> Void) {
        self.launch = launch
        self.layout = layout
        self.onChange = onChange
        self.requestPermission = requestPermission
        // The app's last policy survives a host restart (the daemon restarts or adopts hosts
        // without the app): a worker starts on it until the app sends another.
        if let saved = Self.loadPolicy(stateDirectory) {
            state.withLock { state in
                state.policy = saved
                state.policyKnown = true
            }
        }
    }

    private var policyFile: String { stateDirectory + "/policy.json" }

    static func loadPolicy(_ directory: String) -> Data? {
        guard let data = FileManager.default.contents(atPath: directory + "/policy.json"),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }

    /// 0600 in the 0700 state directory, replaced atomically.
    private func savePolicy(_ policy: Data) {
        guard LocalSocket.makePrivateDirectory(launch.stateDirectory), LocalSocket.makePrivateDirectory(stateDirectory) else { return }
        let temporary = policyFile + ".tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: policy, attributes: [.posixPermissions: 0o600]),
              rename(temporary, policyFile) == 0 else {
            unlink(temporary)
            logger.error("Computer Use: could not save the policy")
            return
        }
    }

    /// Where the engine keeps sessions, approvals and its audit log (0700): per app build, like the device.
    var stateDirectory: String { launch.stateDirectory + "/computer-use" }

    var pid: pid_t? { state.withLock { $0.child?.pid } }
    var startedAt: Date? { state.withLock { $0.startedAt } }
    var restarts: Int { state.withLock { $0.restarts } }
    var phase: Phase { state.withLock { $0.phase } }

    /// The policy's mode is "off": no worker runs whatever the switch says.
    var policyIsOff: Bool { state.withLock { Self.mode(of: $0.policy) == "off" } }

    /// The status fields of `workers["computer-use"]`.
    func statusFields(grantsChangedAt: Date) -> [String: Any] {
        state.withLockUnchecked { state in
            var fields: [String: Any] = ["state": state.phase.rawValue, "restarts": state.restarts,
                                         "mode": Self.mode(of: state.policy)]
            if let pid = state.child?.pid { fields["pid"] = Int(pid) }
            if let reason = state.reason { fields["reason"] = reason }
            if let started = state.startedAt { fields["stale"] = started < grantsChangedAt }
            fields["activity"] = state.activity.fields
            return fields
        }
    }

    static func mode(of policy: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: policy)) as? [String: Any])?["mode"] as? String ?? "fullAccess"
    }

    // MARK: Switches

    /// On: start the worker when none runs, once the app's policy is known and not off. Off: stop it.
    func setWanted(_ wanted: Bool) {
        let start = state.withLock { state -> Bool in
            state.switchOn = wanted
            state.wanted = wanted && state.policyKnown && Self.mode(of: state.policy) != "off"
            if !state.wanted {
                state.startAfterExit = false
                if state.child == nil {
                    let waiting = wanted && !state.policyKnown
                    state.phase = waiting ? .starting : .off
                    state.reason = waiting ? "waiting for the cmux app's Computer Use settings" : nil
                }
            }
            return state.wanted && state.child == nil
        }
        if start { self.start() } else if !state.withLock({ $0.wanted }) { stop() }
        onChange()
    }

    /// `computer_use.config`: the person's policy (PolicyConfig JSON, from the verified app through
    /// the daemon), the cursor motion and the machine name. A running worker gets it at once.
    func configure(policy: Data, motion: [String: Any]?, machine: String?, computerUse: Bool) {
        savePolicy(policy)
        let channel = state.withLockUnchecked { state -> LineChannel? in
            state.policy = policy
            state.policyKnown = true
            if let motion { state.motion = motion }
            if let machine, !machine.isEmpty { state.machine = machine }
            return state.phase == .ready ? state.channel : nil
        }
        if let channel {
            var line: [String: Any] = ["type": "config", "config": Self.object(policy)]
            line["motion"] = state.withLockUnchecked { $0.motion }
            channel.write(RemoteWire.line(line))
        }
        setWanted(computerUse)
    }

    /// Restarts the worker (a new process sees new grants). Grants and sessions live in its state directory.
    func restart() {
        let running = state.withLock { state -> Bool in
            guard state.child != nil else { return false }
            state.startAfterExit = true
            return true
        }
        if running { stop(keepWanted: true) }
    }

    /// The agent socket for the daemon (`computer_use.endpoint`): waits up to `wait` (on the caller's
    /// thread, never the main thread) for a starting worker.
    func endpoint(wait: TimeInterval) -> [String: Any] {
        let deadline = Date().addingTimeInterval(wait)
        readyCondition.lock()
        defer { readyCondition.unlock() }
        while true {
            let snapshot = state.withLockUnchecked { ($0.phase, $0.endpoint, $0.reason, $0.wanted) }
            switch snapshot.0 {
            case .ready:
                if let endpoint = snapshot.1 {
                    return ["state": "ready", "socket": endpoint.socket, "secret": endpoint.secret, "pid": Int(endpoint.pid)]
                }
            case .off:
                return ["state": "off", "reason": "Computer Use is off"]
            case .unavailable:
                return ["state": "unavailable", "reason": snapshot.2 ?? "the Computer Use worker could not start"]
            case .starting:
                break
            }
            guard snapshot.3, readyCondition.wait(until: deadline) else {
                return ["state": "starting", "reason": snapshot.2 ?? "the Computer Use worker is starting"]
            }
        }
    }

    /// One control request to the running worker (`approvals`); `{"ok":false,...}` shaped when none runs.
    func request(_ fields: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { (continuation: CheckedContinuation<WorkerReply, Never>) in
            nonisolated(unsafe) let fields = fields
            let target = state.withLockUnchecked { state -> (LineChannel, Int)? in
                guard state.phase == .ready, let channel = state.channel else { return nil }
                let id = state.nextID
                state.nextID += 1
                state.pending[id] = continuation
                return (channel, id)
            }
            guard let (channel, id) = target else {
                continuation.resume(returning: WorkerReply(["ok": false, "error": ["code": "worker_unavailable",
                                                                                   "message": "the Computer Use worker is not running"]]))
                return
            }
            var line = fields
            line["id"] = id
            if !channel.write(RemoteWire.line(line)) {
                let waiting = state.withLockUnchecked { $0.pending.removeValue(forKey: id) }
                waiting?.resume(returning: WorkerReply(["ok": false, "error": ["code": "worker_unavailable", "message": "the worker stopped"]]))
            }
        }.value
    }

    // MARK: The process

    private func start() {
        guard LocalSocket.makePrivateDirectory(launch.stateDirectory), LocalSocket.makePrivateDirectory(stateDirectory) else {
            return settle(.unavailable, reason: "\(stateDirectory) is not a private directory of this user")
        }
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(executable: launch.executable, arguments: launch.arguments(.computerUse, layout: layout),
                                           environment: launch.environment, logPath: launch.logPath)
        } catch {
            logger.error("Computer Use worker did not start: \(String(describing: error), privacy: .public)")
            settle(.unavailable, reason: "the Computer Use worker did not start: \(error)")
            scheduleRestart(ranFor: 0)
            return
        }
        let secret = RemoteWire.hex(RemoteWire.makeSecret())
        let channel = LineChannel(read: child.stdout, write: child.stdin)
        let (generation, configure) = state.withLockUnchecked { state -> (Int, Data) in
            state.child = child
            state.channel = channel
            state.startedAt = Date()
            state.phase = .starting
            state.reason = nil
            state.endpoint = Endpoint(socket: layout.computerUseSocket, secret: secret, pid: child.pid)
            state.generation += 1
            let line: [String: Any] = ["type": "configure", "config": Self.object(state.policy), "socket": layout.computerUseSocket,
                                       "secret": secret, "state_dir": stateDirectory, "machine": state.machine, "motion": state.motion]
            return (state.generation, RemoteWire.line(line))
        }
        logger.notice("Computer Use worker started pid=\(child.pid, privacy: .public)")
        channel.write(configure)
        let started = Date()
        let reader = Thread { [self] in
            while let object = channel.readObject() { handle(object, generation: generation) }
            close(child.stdout)
        }
        reader.name = "remote-cu-worker-read"
        reader.start()
        ChildProcess.watch(child.pid, name: "remote-cu-worker-watch") { [self] status in
            exited(generation: generation, status: status, ranFor: Date().timeIntervalSince(started), channel: channel)
        }
        onChange()
    }

    private func handle(_ object: [String: Any], generation: Int) {
        if let id = object["id"] as? Int {
            let waiting = state.withLockUnchecked { $0.pending.removeValue(forKey: id) }
            waiting?.resume(returning: WorkerReply(object))
            return
        }
        guard state.withLock({ $0.generation == generation }) else { return }
        switch object["type"] as? String {
        case "ready":
            settle(.ready, reason: nil)
        case "unavailable":
            settle(.unavailable, reason: object["reason"] as? String ?? "the Computer Use engine could not start")
        case "activity":
            // A session acted or ended (the worker sends at most a few a second): the daemon
            // hears it in the next status (`computer-use-activity`).
            guard state.withLockUnchecked({ $0.activity.take(object, now: Date()) }) else { return }
            onChange()
        case "request_permission":
            if let permission = (object["permission"] as? String).flatMap(RemotePermission.init(rawValue:)) {
                requestPermission(permission)
            }
        default:
            break
        }
    }

    private func settle(_ phase: Phase, reason: String?) {
        state.withLock { state in
            state.phase = phase
            state.reason = reason
            if phase != .ready, phase != .starting { state.endpoint = nil }
            if phase == .ready { state.backoff = RestartBackoff() }
        }
        readyCondition.lock()
        readyCondition.broadcast()
        readyCondition.unlock()
        onChange()
    }

    private func stop(keepWanted: Bool = false) {
        let channel = state.withLockUnchecked { state -> LineChannel? in
            guard state.child != nil else { return nil }
            defer {
                state.channel = nil
                state.endpoint = nil
                state.phase = keepWanted ? .starting : .off
            }
            return state.channel
        }
        guard let channel else { return }
        // EOF on its stdin stops the worker; `exited` starts the next one when asked.
        channel.closeWrite()
        failPending("the worker stopped")
        readyCondition.lock()
        readyCondition.broadcast()
        readyCondition.unlock()
        onChange()
    }

    /// Ends the worker for good (the host is shutting down).
    func stopAll() {
        state.withLock { state in
            state.switchOn = false
            state.wanted = false
            state.startAfterExit = false
        }
        stop()
        if let pid { kill(pid, SIGTERM) }
    }

    private func exited(generation: Int, status: Int32, ranFor seconds: Double, channel: LineChannel) {
        channel.closeWrite()
        let outcome = state.withLockUnchecked { state -> (current: Bool, startNow: Bool) in
            guard state.generation == generation, state.child != nil else { return (false, false) }
            state.child = nil
            state.channel = nil
            state.endpoint = nil
            state.startedAt = nil
            // Its sessions act no more (a new worker reports them again when they do).
            state.activity = ComputerUseActivity()
            let startNow = state.startAfterExit && state.wanted
            state.startAfterExit = false
            if !state.wanted { state.phase = .off } else if state.phase != .unavailable { state.phase = .starting }
            return (true, startNow)
        }
        guard outcome.current else { return }
        failPending("the worker exited")
        unlink(layout.computerUseSocket)
        readyCondition.lock()
        readyCondition.broadcast()
        readyCondition.unlock()
        onChange()
        if outcome.startNow {
            logger.notice("Computer Use worker stopped for a restart; starting the next one")
            return start()
        }
        logger.error("Computer Use worker exited status=\(status, privacy: .public) after \(Int(seconds), privacy: .public) s")
        scheduleRestart(ranFor: seconds)
    }

    private func scheduleRestart(ranFor seconds: Double) {
        let delay = state.withLock { state -> Double? in
            guard state.wanted else { return nil }
            state.restarts += 1
            return state.backoff.delay(afterRunOf: seconds)
        }
        guard let delay else { return }
        // A bounded restart delay after a crash (RestartBackoff), not a synchronization.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            let start = state.withLock { $0.wanted && $0.child == nil }
            if start { self.start() }
        }
    }

    private func failPending(_ message: String) {
        let waiting = state.withLockUnchecked { state -> [CheckedContinuation<WorkerReply, Never>] in
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        for continuation in waiting {
            continuation.resume(returning: WorkerReply(["ok": false, "error": ["code": "worker_unavailable", "message": message]]))
        }
    }

    static func object(_ policy: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: policy)) as? [String: Any] ?? [:]
    }
}
