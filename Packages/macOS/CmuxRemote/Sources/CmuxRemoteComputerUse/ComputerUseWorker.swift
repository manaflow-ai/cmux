// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
import CCmuxComputerUse
import CmuxRemoteWire
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "computer-use")

/// The Computer Use worker (`cmux-remote worker computer-use`): one long-lived child of the
/// cmux Remote host, so macOS checks its Accessibility and Screen Recording as cmux Remote's. It
/// hosts the cmux Computer Use engine (libcmux_computer_use.dylib in this bundle's Frameworks)
/// and serves the agent socket through it (`cmux_cu_serve`, cmux-computer-use-v1). The engine
/// does everything but the AppKit and ScreenCaptureKit parts, which this worker supplies as its
/// host callbacks: `capture` (ScreenCapture), `cursor` (AgentCursorOverlay), `ask`
/// (ApprovalPanel), `wait_idle` (the takeover tap) and `request_permission` (a line to the host,
/// whose PermissionAuthority asks macOS).
///
/// stdin and stdout are the host's control lines (WorkerControl): the first line configures it,
/// later lines change the policy or the saved approvals, and EOF on stdin stops it.
public struct ComputerUseWorker: Sendable {
    public init() {}

    /// Never returns. Runs AppKit on the main thread (the cursor and the approval panel).
    @MainActor public func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let services = WorkerServices(output: LineChannel(read: STDIN_FILENO, write: STDOUT_FILENO))
        services.start()
        app.run()
        exit(0)
    }
}

/// What the engine's callbacks reach (their context) and the control loop. One per process, kept
/// for its life (the engine holds a raw pointer to it).
final class WorkerServices: @unchecked Sendable { // crash-allow: mutable state is behind `lock`; the AppKit parts are touched on the main actor only
    let channel: LineChannel
    let tap = TakeoverTap()
    /// Which agent sessions act, for the host (the app's menu bar badge and Computer Use row).
    let activity: ComputerUseActivityReporter
    private let lock = NSLock()
    private var engine: ComputerUseEngine?
    private var server: ServerHandle?
    private var flags = PolicyFlags()
    /// Set before the server stops: questions asked from now on answer
    /// `unavailable` at once, so stopping (which waits for running calls)
    /// never waits on an open approval panel.
    private var stopping = false
    /// Set on the main actor.
    nonisolated(unsafe) private var overlay: AgentCursorOverlay?
    nonisolated(unsafe) private var approvals: ApprovalPanel?

    init(output: LineChannel) {
        channel = output
        activity = ComputerUseActivityReporter(write: { line in _ = output.write(line) })
    }

    @MainActor func start() {
        overlay = AgentCursorOverlay()
        approvals = ApprovalPanel()
        let reader = Thread { [self] in readLoop() }
        reader.name = "remote-cu-control"
        reader.start()
    }

    // MARK: Control lines

    private func readLoop() {
        while let line = channel.readObject() {
            guard let control = WorkerControl(line: line) else {
                logger.error("Computer Use worker: a malformed control line")
                continue
            }
            handle(control, id: line["id"] as? Int)
        }
        // The host closed stdin: stop. Open questions are answered first, so
        // the calls waiting on them finish; then the server stops, which waits
        // for running calls (cmux_cu_serve_stop is called only from this thread).
        logger.notice("Computer Use worker: the host closed the control channel; stopping")
        let (engine, server) = lock.withLock { () -> (ComputerUseEngine?, ServerHandle?) in
            stopping = true
            return (self.engine, self.server)
        }
        // concurrency-allow: this is the control thread (never main); the main actor only answers the open panels.
        DispatchQueue.main.sync { MainActor.assumeIsolated { self.approvals?.cancelAll() } }
        if let engine, let server { engine.stopServing(server) }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.overlay?.hideAll() }
            exit(0)
        }
    }

    private func handle(_ control: WorkerControl, id: Int?) {
        switch control {
        case .configure(let configuration):
            configure(configuration)
        case .config(let policy, let motion):
            let engine = lock.withLock { () -> ComputerUseEngine? in
                flags = PolicyFlags(policy)
                return self.engine
            }
            applyFlags(motion: motion)
            do {
                try engine?.setConfig(policy)
                if let id { channel.write(RemoteWire.answer(id: id, result: [:])) }
            } catch {
                if let id { channel.write(RemoteWire.failure(id: id, code: "bad_config", message: String(describing: error))) }
            }
        case .approvals(let id, let edit):
            guard let engine = lock.withLock({ self.engine }) else {
                if let id { channel.write(RemoteWire.failure(id: id, code: "worker_unavailable", message: "the engine is not running")) }
                return
            }
            if let (action, app) = edit.engineArguments, !engine.edit(action: action, appID: app) {
                if let id { channel.write(RemoteWire.failure(id: id, code: "bad_request", message: "the engine refused \(action)")) }
                return
            }
            if let id { channel.write(RemoteWire.answer(id: id, result: engine.savedApprovals())) }
        case .session(let id, let control):
            guard let engine = lock.withLock({ self.engine }) else {
                if let id { channel.write(RemoteWire.failure(id: id, code: "worker_unavailable", message: "the engine is not running")) }
                return
            }
            // Before a stop, so the engine's red Stopped cursor event is not counted as an action.
            if control.action == .stop { activity.noteStopped(control.session, true) }
            let result = engine.apply(control)
            if control.action == .resume, result != .refused { activity.noteStopped(control.session, false) }
            guard result != .refused else {
                if control.action == .stop { activity.noteStopped(control.session, false) }
                if let id { channel.write(RemoteWire.failure(id: id, code: "bad_request", message: "the engine refused \(control.action.rawValue)")) }
                return
            }
            logger.notice("Computer Use: the person chose \(control.action.rawValue, privacy: .public) for an agent session")
            if let id {
                channel.write(RemoteWire.answer(id: id, result: ["session": control.session, "stopped": control.action == .stop,
                                                                 "changed": result == .changed]))
            }
        case .spotlight(let id, let session):
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let shown = self.overlay?.spotlight(session: session) ?? false
                    if let id { self.channel.write(RemoteWire.answer(id: id, result: ["shown": shown])) }
                }
            }
        case .raiseWindow(let id, let session):
            // The control thread (never main): accessibility calls may wait on the target app.
            guard let place = activity.window(of: session) else {
                if let id { channel.write(RemoteWire.failure(id: id, code: "no_window", message: "this agent has not worked in a window yet")) }
                return
            }
            guard let pid = WindowRaise.raise(window: place.window, pid: place.pid) else {
                if let id { channel.write(RemoteWire.failure(id: id, code: "no_window", message: "the agent's window is gone")) }
                return
            }
            if let id { channel.write(RemoteWire.answer(id: id, result: ["raised": true, "pid": Int(pid)])) }
        case .unknown(let id, let type):
            if let id { channel.write(RemoteWire.failure(id: id, code: "unknown_method", message: "unknown control line \(type)")) }
        }
    }

    private func configure(_ configuration: WorkerConfiguration) {
        guard lock.withLock({ self.engine == nil }) else {
            logger.error("Computer Use worker: configured twice; ignored")
            return
        }
        guard LocalSocket.makePrivateDirectory(configuration.stateDirectory) else {
            return unavailable("\(configuration.stateDirectory) is not a private directory of this user")
        }
        let library: ComputerUseLibrary
        do { library = try ComputerUseLibrary(path: ComputerUseLibrary.bundledPath()) } catch {
            return unavailable(String(describing: error))
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let engine: ComputerUseEngine
        do {
            // The engine copies the table at create.
            var host = Self.callbacks(context: context)
            engine = try withUnsafePointer(to: &host) { pointer in
                try ComputerUseEngine(library: library, policy: configuration.policy, stateDirectory: configuration.stateDirectory,
                                      machine: configuration.machine, host: pointer)
            }
        } catch {
            return unavailable(String(describing: error))
        }
        let server: ServerHandle
        do { server = try engine.serve(socket: configuration.socket, secret: configuration.secret) } catch {
            return unavailable("cannot serve the agent socket \(configuration.socket): \(error)")
        }
        lock.withLock {
            self.engine = engine
            self.server = server
            flags = PolicyFlags(configuration.policy)
        }
        applyFlags(motion: configuration.motion)
        logger.notice("Computer Use worker ready pid=\(getpid(), privacy: .public)")
        channel.write(WorkerReport.ready(pid: getpid(), socket: configuration.socket))
    }

    private func unavailable(_ reason: String) {
        logger.error("Computer Use worker unavailable: \(reason, privacy: .public)")
        channel.write(WorkerReport.unavailable(reason))
    }

    private func applyFlags(motion: CursorMotionSettings?) {
        let flags = lock.withLock { self.flags }
        if flags.pauseOnTakeover { tap.ensureStarted() } else { tap.stop() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let motion { self.overlay?.motion = motion }
                self.overlay?.enabled = flags.showCursor && !flags.isOff
                if flags.isOff { self.approvals?.cancelAll() }
            }
        }
    }

    // MARK: Engine callbacks (any engine thread)

    fileprivate func capture(_ target: Data, frame: UnsafeMutablePointer<CmuxCuFrame>, error: UnsafeMutablePointer<UInt8>?,
                             errorCapacity: Int) -> Int32 {
        guard let target = CaptureTarget(json: target) else { return Self.fail("bad capture target", error, errorCapacity) }
        activity.noteCapture(target)
        switch ScreenCapture().capture(target) {
        case .failure(let failure):
            return Self.fail(failure.description, error, errorCapacity)
        case .success(let captured):
            let pixels = FrameStorage(captured.rgba)
            frame.pointee.width = UInt32(captured.width)
            frame.pointee.height = UInt32(captured.height)
            frame.pointee.rgba = pixels.base
            frame.pointee.scale = captured.scale
            frame.pointee.origin_x = captured.origin.x
            frame.pointee.origin_y = captured.origin.y
            frame.pointee.host_token = Unmanaged.passRetained(pixels).toOpaque()
            return 0
        }
    }

    /// The capture's apps as JSON into `out`; 2 when `capacity` is too small (`length` says how much).
    fileprivate func captureApps(out: UnsafeMutablePointer<UInt8>?, capacity: Int, length: UnsafeMutablePointer<Int>) -> Int32 {
        guard case .success(let data) = ScreenCapture().applications() else { return 1 }
        length.pointee = data.count
        guard let out, data.count <= capacity else { return 2 }
        data.copyBytes(to: out, count: data.count)
        return 0
    }

    fileprivate func cursor(_ json: Data) {
        activity.noteCursor(json)
        guard let event = AgentCursorEvent(json: json) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.overlay?.show(event) } }
    }

    /// Blocks the engine's thread until the person answers (or the panel's timeout).
    fileprivate func ask(_ json: Data) -> Int32 {
        guard let question = ApprovalQuestion(json: json),
              !lock.withLock({ stopping }) else { return ApprovalAnswer.unavailable.rawValue }
        activity.noteQuestion(question)
        let box = OSAllocatedUnfairLock(initialState: ApprovalAnswer.unavailable)
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let approvals = self.approvals, !self.lock.withLock({ self.stopping }) else {
                    answered.signal()
                    return
                }
                approvals.ask(question) { answer in
                    box.withLock { $0 = answer }
                    answered.signal()
                }
            }
        }
        // concurrency-allow: `ask` blocks by contract on an engine thread (never main); the panel answers within its timeout.
        guard answered.wait(timeout: .now() + ApprovalPanel.timeout + 5) == .success else { return ApprovalAnswer.unavailable.rawValue }
        return box.withLock { $0 }.rawValue
    }

    fileprivate func waitIdle(limitMilliseconds: UInt64) -> Bool {
        guard lock.withLock({ flags.pauseOnTakeover }) else { return true }
        return tap.gate.waitIdle(limit: .milliseconds(Int64(min(limitMilliseconds, 600_000))))
    }

    fileprivate func requestPermission(_ name: String) -> Int32 {
        guard let line = WorkerReport.requestPermission(name) else { return 1 }
        return channel.write(line) ? 0 : 1
    }

    private static func fail(_ message: String, _ error: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int32 {
        if let error, capacity > 0 {
            var count = 0
            for byte in message.utf8.prefix(capacity - 1) {
                error[count] = byte
                count += 1
            }
            error[count] = 0
        }
        return 1
    }

    // MARK: The C table

    fileprivate static func services(_ context: UnsafeMutableRawPointer?) -> WorkerServices? {
        context.map { Unmanaged<WorkerServices>.fromOpaque($0).takeUnretainedValue() }
    }

    fileprivate static func data(_ pointer: UnsafePointer<UInt8>?, _ length: Int) -> Data {
        guard let pointer, length > 0 else { return Data() }
        return Data(bytes: pointer, count: length)
    }

    static func callbacks(context: UnsafeMutableRawPointer) -> CmuxCuHost {
        var host = CmuxCuHost()
        host.struct_size = UInt32(MemoryLayout<CmuxCuHost>.size)
        host.context = context
        host.capture = { context, target, length, frame, error, capacity in
            guard let services = WorkerServices.services(context), let frame else { return 1 }
            return services.capture(WorkerServices.data(target, length), frame: frame, error: error, errorCapacity: capacity)
        }
        host.release_frame = { _, token in
            if let token { Unmanaged<FrameStorage>.fromOpaque(token).release() }
        }
        host.cursor = { context, json, length in
            WorkerServices.services(context)?.cursor(WorkerServices.data(json, length))
        }
        host.ask = { context, json, length in
            WorkerServices.services(context)?.ask(WorkerServices.data(json, length)) ?? ApprovalAnswer.unavailable.rawValue
        }
        host.wait_idle = { context, limit in
            WorkerServices.services(context)?.waitIdle(limitMilliseconds: limit) ?? true
        }
        host.request_permission = { context, name, length in
            WorkerServices.services(context)?.requestPermission(String(decoding: WorkerServices.data(name, length), as: UTF8.self)) ?? 1
        }
        host.capture_apps = { context, out, capacity, length in
            guard let services = WorkerServices.services(context), let length else { return 1 }
            return services.captureApps(out: out, capacity: capacity, length: length)
        }
        return host
    }
}

/// A captured frame's bytes, kept alive until the engine calls `release_frame`.
final class FrameStorage {
    private let storage: UnsafeMutableBufferPointer<UInt8>
    var base: UnsafePointer<UInt8>? { UnsafePointer(storage.baseAddress) }

    init(_ data: Data) {
        storage = .allocate(capacity: max(data.count, 1))
        _ = storage.initialize(from: data)
    }

    deinit { storage.deallocate() }
}
