import Foundation
import CryptoKit
import Darwin
import OwlFreshRuntimeShim

/// Runs OWL's thread-affine Chromium ABI on one persistent OS thread.
///
/// The released OWL runtime creates Chromium's `SingleThreadTaskRunner` from
/// the thread that calls `owl_shim_global_init`. Chromium then expects session
/// creation, event polling, input, evaluation, surface capture, and teardown to
/// remain on that same thread. A serial dispatch queue is insufficient here:
/// libdispatch may execute successive jobs on different threads.
private final class OwlFreshRuntimeExecutor: @unchecked Sendable {
    private final class Job: @unchecked Sendable {
        let operation: @Sendable () -> Void

        init(operation: @escaping @Sendable () -> Void) {
            self.operation = operation
        }
    }

    private final class ResultBox<Value>: @unchecked Sendable {
        var result: Result<Value, Error>?
    }

    private struct ExecutorStopped: Error {}

    private func isWorkerThread() -> Bool {
        Thread.current === workerThread
    }

    private let lock = NSLock()
    private let jobsSemaphore = DispatchSemaphore(value: 0)
    private let readySemaphore = DispatchSemaphore(value: 0)
    private var jobs: [Job] = []
    private var stopped = false
    private var workerThread: Thread? = nil

    init() {
        workerThread = Thread { [self] in
            run()
        }
        workerThread?.name = "cmux.owl-runtime"
        workerThread?.qualityOfService = .userInitiated
        workerThread?.start()
        readySemaphore.wait()
    }

    deinit {
        stop()
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        if isWorkerThread() {
            return try operation()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let accepted = enqueue(Job {
                continuation.resume(with: Result { try operation() })
            })
            if !accepted {
                continuation.resume(throwing: ExecutorStopped())
            }
        }
    }

    @discardableResult
    func submit(_ operation: @escaping @Sendable () -> Void) -> Bool {
        enqueue(Job(operation: operation))
    }

    /// Synchronous fire-and-forget is reserved for deinitialization, where an
    /// escaping callback must stay retained until its queued teardown runs.
    func submitAndWait(_ operation: @escaping @Sendable () -> Void) {
        if isWorkerThread() {
            operation()
            return
        }
        let completion = DispatchSemaphore(value: 0)
        guard enqueue(Job {
            operation()
            completion.signal()
        }) else {
            return
        }
        completion.wait()
    }

    func stop() {
        if Thread.current === workerThread {
            lock.lock()
            stopped = true
            lock.unlock()
            return
        }

        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        jobsSemaphore.signal()
    }

    @discardableResult
    private func enqueue(_ job: Job) -> Bool {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return false
        }
        jobs.append(job)
        lock.unlock()
        jobsSemaphore.signal()
        return true
    }

    private func run() {
        workerThread = Thread.current
        readySemaphore.signal()

        while true {
            jobsSemaphore.wait()
            lock.lock()
            let job = jobs.isEmpty ? nil : jobs.removeFirst()
            let shouldStop = stopped && jobs.isEmpty
            lock.unlock()

            if let job {
                job.operation()
            }
            if shouldStop {
                break
            }
        }
    }
}

/// Owns one OWL Content Shell session and translates its native compositor events.
final class OwlFreshRuntime: @unchecked Sendable {
    struct Event: Sendable {
        let kind: Int
        let contextID: UInt32
        let loading: Bool
        let url: String?
        let title: String?
        let message: String?
    }
    typealias EventHandler = @Sendable (Event) -> Void

    private var session: OpaquePointer?
    private let handler: EventHandler
    private let executor: OwlFreshRuntimeExecutor
    private var callbackBox: UnmanagedCallbackBox

    private final class UnmanagedCallbackBox: @unchecked Sendable {
        let handler: EventHandler
        init(_ handler: @escaping EventHandler) { self.handler = handler }
    }

    private final class SessionBox: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
    }

    /// Returns a launcher outside the signed Content Shell bundle that adds
    /// the validated unpacked-extension allowlist before the OWL runtime's
    /// positional initial URL argument.
    static func shellExecutable(
        for shell: URL,
        extensionDirectories: [URL],
        wrapperDirectory: URL? = nil
    ) throws -> URL {
        let paths = extensionDirectories
            .map { $0.standardizedFileURL.path }
            .filter { !$0.isEmpty && !$0.contains(",") }
        guard !paths.isEmpty else { return shell }

        let joined = paths.joined(separator: ",")
        let digest = SHA256.hash(data: Data(joined.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let defaultWrapperDirectory = shell
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resolvedWrapperDirectory = wrapperDirectory ?? defaultWrapperDirectory
        try FileManager.default.createDirectory(
            at: resolvedWrapperDirectory,
            withIntermediateDirectories: true
        )
        let wrapper = resolvedWrapperDirectory
            .appendingPathComponent(".cmux-owl-shell-\(digest)", isDirectory: false)
        let quote: (String) -> String = { value in
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let script = "#!/bin/sh\nexec \(quote(shell.path)) \(quote("--disable-extensions-except=\(joined)")) \(quote("--load-extension=\(joined)")) \"$@\"\n"
        let data = Data(script.utf8)
        if let existing = try? Data(contentsOf: wrapper), existing != data {
            try data.write(to: wrapper, options: .atomic)
        } else if !FileManager.default.fileExists(atPath: wrapper.path) {
            try data.write(to: wrapper, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: wrapper.path
        )
        return wrapper
    }

    private init(handler: @escaping EventHandler) {
        self.handler = handler
        self.callbackBox = UnmanagedCallbackBox(handler)
        self.executor = OwlFreshRuntimeExecutor()
        self.session = nil
    }

    /// Creates the runtime and performs every OWL initialization call on its
    /// dedicated thread before returning it to the browser session actor.
    static func create(
        shell: URL,
        runtimeShell: URL? = nil,
        initialURL: URL,
        profile: URL,
        handler: @escaping EventHandler
    ) async throws -> OwlFreshRuntime {
        let runtime = OwlFreshRuntime(handler: handler)
        let dylibAnchor = runtimeShell ?? shell
        let dylib = dylibAnchor
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("libowl_fresh_mojo_runtime.dylib")
        let callbackBox = runtime.callbackBox

        do {
            try await runtime.executor.perform {
                guard owl_shim_open(dylib.path) == 0 else {
                    throw CDPError.disconnected("OWL runtime dylib unavailable")
                }
                guard owl_shim_global_init() == 0 else {
                    throw CDPError.disconnected("OWL runtime initialization failed")
                }
                let userData = Unmanaged.passUnretained(callbackBox).toOpaque()
                let callback: OwlShimCallback = { event, userData in
                    guard let event, let userData else { return }
                    let box = Unmanaged<UnmanagedCallbackBox>.fromOpaque(userData).takeUnretainedValue()
                    box.handler(Event(
                        kind: Int(event.pointee.kind),
                        contextID: UInt32(event.pointee.context_id),
                        loading: event.pointee.loading,
                        url: event.pointee.url.map { String(cString: $0) },
                        title: event.pointee.title.map { String(cString: $0) },
                        message: event.pointee.message.map { String(cString: $0) }
                    ))
                }
                guard let session = owl_shim_session_create(
                    shell.path,
                    initialURL.absoluteString,
                    profile.path,
                    callback,
                    userData
                ) else {
                    throw CDPError.disconnected("OWL Content Shell could not start")
                }
                guard owl_shim_bind_all(session) == 0 else {
                    owl_shim_session_destroy(session)
                    throw CDPError.disconnected("OWL Mojo session binding failed")
                }
                runtime.session = session
            }
        } catch {
            runtime.executor.stop()
            throw error
        }
        return runtime
    }

    deinit {
        if let session {
            self.session = nil
            let sessionBox = SessionBox(session)
            executor.submitAndWait {
                owl_shim_session_destroy(sessionBox.pointer)
            }
        }
        executor.stop()
    }

    /// Stops the Content Shell and waits until its host process has exited.
    ///
    /// The OWL runtime's destroy call requests shutdown and waits briefly, but
    /// it can return while the host still owns the profile lock. Capture the
    /// host PID before destroying the Mojo session, then keep the replacement
    /// launch serialized until that process is gone.
    func shutdownAndWait() async -> Bool {
        let pid: Int32
        do {
            pid = try await executor.perform {
                guard let session = self.session else { return 0 }
                let pid = owl_shim_session_host_pid(session)
                self.session = nil
                owl_shim_session_destroy(session)
                return pid
            }
        } catch {
            executor.stop()
            return false
        }
        executor.stop()
        guard pid > 0 else { return true }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while processIsAlive(pid) {
            if Task.isCancelled {
                _ = Darwin.kill(pid, SIGKILL)
                break
            }
            guard clock.now < deadline else {
                _ = Darwin.kill(pid, SIGKILL)
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !processIsAlive(pid)
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// Waits for native Mojo work and dispatches callbacks without busy polling.
    func poll() async {
        _ = try? await executor.perform {
            owl_shim_poll(250)
        }
    }

    func navigate(_ url: URL) async throws {
        try await executor.perform {
            guard let session = self.session,
                  owl_shim_navigate(session, url.absoluteString) == 0 else {
                throw CDPError.notConnected
            }
        }
    }

    func resize(width: Int, height: Int, scale: Double) async throws {
        try await executor.perform {
            guard let session = self.session,
                  owl_shim_resize(
                      session,
                      UInt32(max(1, width)),
                      UInt32(max(1, height)),
                      Float(scale)
                  ) == 0 else {
                throw CDPError.notConnected
            }
        }
    }

    func focus(_ focused: Bool) async throws {
        try await executor.perform {
            guard let session = self.session,
                  owl_shim_focus(session, focused) == 0 else {
                throw CDPError.notConnected
            }
        }
    }

    func mouse(
        kind: UInt32,
        x: Double,
        y: Double,
        button: UInt32,
        clickCount: UInt32,
        deltaX: Double,
        deltaY: Double,
        modifiers: UInt32
    ) async throws {
        try await executor.perform {
            guard let session = self.session,
                  owl_shim_mouse(
                      session,
                      kind,
                      Float(x),
                      Float(y),
                      button,
                      clickCount,
                      Float(deltaX),
                      Float(deltaY),
                      modifiers
                  ) == 0 else {
                throw CDPError.notConnected
            }
        }
    }

    func key(down: Bool, keyCode: UInt32, text: String?, modifiers: UInt32) async throws {
        try await executor.perform {
            guard let session = self.session,
                  owl_shim_key(session, down, keyCode, text, modifiers) == 0 else {
                throw CDPError.notConnected
            }
        }
    }

    func evaluate(_ script: String) async throws -> String {
        try await executor.perform {
            guard let session = self.session else { throw CDPError.notConnected }
            var result: UnsafeMutablePointer<CChar>?
            guard owl_shim_eval(session, script, &result) == 0 else {
                throw CDPError.commandFailed("OWL JavaScript evaluation failed")
            }
            defer {
                if let result { owl_shim_free(result) }
            }
            return result.map { String(cString: $0) } ?? "null"
        }
    }

    func surfaceTreeJSON() async throws -> String {
        try await executor.perform {
            guard let session = self.session else { throw CDPError.notConnected }
            var result: UnsafeMutablePointer<CChar>?
            guard owl_shim_surface_json(session, &result) == 0 else {
                throw CDPError.commandFailed("OWL surface tree unavailable")
            }
            defer {
                if let result { owl_shim_free(result) }
            }
            return result.map { String(cString: $0) } ?? "{}"
        }
    }

    /// Captures the active OWL web surface as PNG bytes through the runtime's
    /// native surface-tree capture path. This keeps browser screenshot and
    /// viewport snapshot commands available without a CDP connection.
    func screenshotPNG() async throws -> Data {
        try await executor.perform {
            guard let session = self.session else { throw CDPError.notConnected }
            var result: UnsafeMutablePointer<CChar>?
            guard owl_shim_capture_surface_json(session, &result) == 0,
                  let result else {
                throw CDPError.commandFailed("OWL surface capture unavailable")
            }
            defer { owl_shim_free(result) }
            guard let data = String(cString: result).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let payload = object as? [String: Any],
                  let encoded = payload["pngBase64"] as? String,
                  let png = Data(base64Encoded: encoded) else {
                throw CDPError.protocolError("OWL surface capture returned invalid PNG data")
            }
            return png
        }
    }
}
