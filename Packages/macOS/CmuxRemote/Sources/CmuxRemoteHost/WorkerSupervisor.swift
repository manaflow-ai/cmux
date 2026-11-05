// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "workers")

/// How a worker is started; the host's own executable in another mode.
struct WorkerLaunch: Sendable {
    var executable: String
    var environment: [String: String]
    var logPath: String
    /// The persistent per-app-build directory and scope (the Screen Sharing worker's device lives there).
    var stateDirectory: String
    var scope: String

    func arguments(_ kind: RemoteWorkerKind, layout: RemoteHostLayout) -> [String] {
        ["worker", kind.rawValue, "--layout-dir", layout.directory, "--state-dir", stateDirectory, "--scope", scope]
    }
}

/// The restart delay after a crash: 200 ms doubling to 30 s, back to 200 ms
/// after a run of 30 s or more.
struct RestartBackoff: Sendable {
    private(set) var next: Double = 0.2
    static let maximum = 30.0
    static let healthyRun = 30.0

    mutating func delay(afterRunOf seconds: Double) -> Double {
        if seconds >= Self.healthyRun { next = 0.2 }
        defer { next = min(next * 2, Self.maximum) }
        return next
    }
}

/// The Screen Sharing worker: one long-lived process while sharing is on.
/// Its stdin and stdout are the host's control lines (requests, answers,
/// `status` events); its own socket serves the app's channels. A crash
/// restarts it after `RestartBackoff`; `restart()` (a grant that the running
/// worker started without) waits for its session to end unless `force`.
final class ScreenWorkerSupervisor: Sendable {
    private let launchBox: OSAllocatedUnfairLock<WorkerLaunch>
    var launch: WorkerLaunch { launchBox.withLock { $0 } }
    let layout: RemoteHostLayout
    /// The latest status the worker reported (or nil while none runs).
    var status: [String: Any]? { state.withLockUnchecked { $0.status } }
    var pid: pid_t? { state.withLock { $0.child?.pid } }
    var startedAt: Date? { state.withLock { $0.startedAt } }
    var restarts: Int { state.withLock { $0.restarts } }
    var busy: Bool { (status?["session"] as? [String: Any]) != nil }
    /// Called (any thread) when the worker's status changes or it stops.
    let onChange: @Sendable () -> Void

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Signalled by the running worker's first `status` (its socket listens by then).
    private let readyCondition = NSCondition()

    private struct State: @unchecked Sendable { // crash-allow: every field is read and written under the lock
        var wanted = false
        var child: ChildProcess?
        var channel: LineChannel?
        var startedAt: Date?
        var status: [String: Any]?
        var pending: [Int: CheckedContinuation<WorkerReply, Never>] = [:]
        var nextID = 1
        var backoff = RestartBackoff()
        var restarts = 0
        /// A restart that waits for the current session to end.
        var restartWhenIdle = false
        /// The stopped worker is still ending: start the next one when it exits.
        var startAfterExit = false
        var generation = 0
    }

    init(launch: WorkerLaunch, layout: RemoteHostLayout, onChange: @escaping @Sendable () -> Void) {
        launchBox = OSAllocatedUnfairLock(initialState: launch)
        self.layout = layout
        self.onChange = onChange
    }

    /// Sets one variable of the next start's environment; true when it changed.
    func setEnvironment(_ name: String, _ value: String) -> Bool {
        launchBox.withLock { launch in
            guard launch.environment[name] != value else { return false }
            launch.environment[name] = value
            return true
        }
    }

    /// On: start the worker when none runs. Off: stop it.
    func setWanted(_ wanted: Bool) {
        let start = state.withLock { state -> Bool in
            state.wanted = wanted
            if !wanted { state.startAfterExit = false }
            return wanted && state.child == nil
        }
        if start { self.start() } else if !wanted { stop() }
    }

    /// Restarts the worker (a new process sees new grants). A worker with a
    /// session restarts after it unless `force`.
    func restart(force: Bool) {
        let now = state.withLock { state -> Bool in
            guard state.child != nil else { return false }
            if !force, (state.status?["session"] as? [String: Any]) != nil {
                state.restartWhenIdle = true
                return false
            }
            return true
        }
        if now {
            // The next worker starts once this one has exited (one device socket at a time).
            state.withLock { $0.startAfterExit = true }
            stop()
        }
    }

    /// One request to the worker; `{"ok":false,...}` shaped when it does not run or stops first.
    func request(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any] {
        await withCheckedContinuation { (continuation: CheckedContinuation<WorkerReply, Never>) in
            nonisolated(unsafe) let params = params
            let channel = state.withLockUnchecked { state -> (LineChannel, Int)? in
                guard let channel = state.channel else { return nil }
                let id = state.nextID
                state.nextID += 1
                state.pending[id] = continuation
                return (channel, id)
            }
            guard let (channel, id) = channel else {
                continuation.resume(returning: WorkerReply(["ok": false, "error": ["code": "worker_unavailable",
                                                                                   "message": "the Screen Sharing worker is not running"]]))
                return
            }
            if !channel.write(RemoteWire.line(["id": id, "method": method, "params": params])) {
                let waiting = state.withLockUnchecked { $0.pending.removeValue(forKey: id) }
                waiting?.resume(returning: WorkerReply(["ok": false, "error": ["code": "worker_unavailable", "message": "the worker stopped"]]))
            }
        }.value
    }

    /// Waits (on the caller's thread, never the main thread) until a running worker has
    /// reported its first status, so its socket listens; false when none runs by `deadline`.
    func waitReady(until deadline: Date) -> Bool {
        readyCondition.lock()
        defer { readyCondition.unlock() }
        while state.withLockUnchecked({ $0.status == nil }) {
            guard state.withLock({ $0.wanted }), readyCondition.wait(until: deadline) else {
                return state.withLockUnchecked { $0.status != nil }
            }
        }
        return true
    }

    private func start() {
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(executable: launch.executable,
                                           arguments: launch.arguments(.screenSharing, layout: layout),
                                           environment: launch.environment, logPath: launch.logPath)
        } catch {
            logger.error("Screen Sharing worker did not start: \(String(describing: error), privacy: .public)")
            scheduleRestart(ranFor: 0)
            return
        }
        let channel = LineChannel(read: child.stdout, write: child.stdin)
        let generation = state.withLockUnchecked { state -> Int in
            state.child = child
            state.channel = channel
            state.startedAt = Date()
            state.generation += 1
            return state.generation
        }
        logger.notice("Screen Sharing worker started pid=\(child.pid, privacy: .public)")
        let started = Date()
        let reader = Thread { [self] in
            while let object = channel.readObject() { handle(object) }
            // The worker's stdout ended (it exited): this thread is its only reader.
            close(child.stdout)
        }
        reader.name = "remote-screen-worker-read"
        reader.start()
        ChildProcess.watch(child.pid, name: "remote-screen-worker-watch") { [self] status in
            exited(generation: generation, status: status, ranFor: Date().timeIntervalSince(started), channel: channel)
        }
        onChange()
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"] as? Int {
            let waiting = state.withLockUnchecked { $0.pending.removeValue(forKey: id) }
            waiting?.resume(returning: WorkerReply(object))
            return
        }
        guard object["type"] as? String == "event" else { return }
        if object["event"] as? String == "status", let status = object["status"] as? [String: Any] {
            readyCondition.lock()
            readyCondition.broadcast()
            readyCondition.unlock()
            let restartNow = state.withLockUnchecked { state -> Bool in
                state.status = status
                guard state.restartWhenIdle, status["session"] == nil else { return false }
                state.restartWhenIdle = false
                return true
            }
            onChange()
            if restartNow { restart(force: true) }
        }
    }

    private func stop() {
        let stopped = state.withLockUnchecked { state -> LineChannel? in
            guard state.child != nil else { return nil }
            defer {
                state.channel = nil
                state.status = nil
                state.restartWhenIdle = false
            }
            return state.channel
        }
        guard let channel = stopped else { return }
        // EOF on its stdin is the worker's stop signal; it ends its session, then exits
        // (`exited` frees the rest and starts the next one when asked).
        channel.closeWrite()
        failPending("the worker stopped")
        onChange()
    }

    private func exited(generation: Int, status: Int32, ranFor seconds: Double, channel: LineChannel) {
        channel.closeWrite()
        let outcome = state.withLockUnchecked { state -> (current: Bool, startNow: Bool) in
            guard state.generation == generation, state.child != nil else { return (false, false) }
            state.child = nil
            state.channel = nil
            state.status = nil
            state.startedAt = nil
            defer { state.startAfterExit = false }
            return (true, state.startAfterExit && state.wanted)
        }
        guard outcome.current else { return }
        failPending("the worker exited")
        onChange()
        if outcome.startNow {
            logger.notice("Screen Sharing worker stopped for a restart; starting the next one")
            return start()
        }
        logger.error("Screen Sharing worker exited status=\(status, privacy: .public) after \(Int(seconds), privacy: .public) s")
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
}

/// One decoded JSON answer, handed from the reader thread to its waiter once.
struct WorkerReply: @unchecked Sendable { // crash-allow: the dictionary is built by one thread and only read by the one waiter after
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

/// Computer Use workers: one per open app channel. The channel is the
/// worker's control pipe (docs/computer-use.md, helper v2): the host splices
/// the app's connection to the worker's stdin and stdout, so the worker exits
/// when the app's channel ends, as the helper did at the app's stdin EOF.
final class ComputerUseWorkers: Sendable {
    let launch: WorkerLaunch
    let layout: RemoteHostLayout
    let onChange: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: [pid_t: Date]())

    init(launch: WorkerLaunch, layout: RemoteHostLayout, onChange: @escaping @Sendable () -> Void) {
        self.launch = launch
        self.layout = layout
        self.onChange = onChange
    }

    /// The running workers' pids and start times.
    var running: [pid_t: Date] { state.withLock { $0 } }

    /// Starts a worker for `channel` and splices them; the channel first gets
    /// `{"ok":true,"result":{"pid":N}}` (or a failure and is closed).
    func open(for channel: LineChannel, id: Any?, environment extra: [String: String]) {
        let child: ChildProcess
        do {
            child = try ChildProcess.spawn(executable: launch.executable,
                                           arguments: launch.arguments(.computerUse, layout: layout),
                                           environment: launch.environment.merging(extra) { $1 }, logPath: launch.logPath)
        } catch {
            channel.write(RemoteWire.failure(id: id, code: "worker_unavailable", message: "the Computer Use worker did not start: \(error)"))
            channel.close()
            return
        }
        state.withLock { $0[child.pid] = Date() }
        onChange()
        logger.notice("Computer Use worker started pid=\(child.pid, privacy: .public)")
        channel.write(RemoteWire.answer(id: id, result: ["pid": Int(child.pid)]))
        let early = channel.takeBuffered()
        if !early.isEmpty { _ = LineChannel.writeAll(child.stdin, early) }
        // Three things end, in any order: the app->worker pump, the worker->app pump and the
        // worker's exit. The last one closes what is left, so no descriptor is freed while a
        // pump still reads or writes its number.
        let ends = OSAllocatedUnfairLock(initialState: 0)
        let finish: @Sendable () -> Void = {
            guard ends.withLock({ count -> Bool in count += 1; return count == 3 }) else { return }
            close(child.stdout)
            channel.close()
        }
        // The app's lines to the worker; the app's EOF ends the worker's stdin, which stops it.
        BytePump.forward(from: channel.readDescriptor, to: child.stdin, name: "remote-cu-to-worker") {
            // This pump is stdin's only writer: closing it here is the worker's EOF (it stops).
            close(child.stdin)
            finish()
        }
        // The worker's lines to the app; its exit ends the app's channel.
        BytePump.forward(from: child.stdout, to: channel.writeDescriptor, name: "remote-cu-from-worker") {
            _ = shutdown(channel.writeDescriptor, SHUT_WR)
            finish()
        }
        ChildProcess.watch(child.pid, name: "remote-cu-worker-watch") { [self] status in
            logger.notice("Computer Use worker pid=\(child.pid, privacy: .public) exited status=\(status, privacy: .public)")
            state.withLock { _ = $0.removeValue(forKey: child.pid) }
            // The app side's read ends too, so its pump finishes.
            _ = shutdown(channel.readDescriptor, SHUT_RDWR)
            onChange()
            finish()
        }
    }

    /// Ends every worker (their channels see EOF; the app starts them again).
    func stopAll() {
        for pid in running.keys { kill(pid, SIGTERM) }
    }
}
