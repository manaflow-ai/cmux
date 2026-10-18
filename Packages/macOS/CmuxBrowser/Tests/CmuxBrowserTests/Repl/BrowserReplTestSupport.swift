import Foundation

@testable import CmuxBrowser

/// Runs `operation` and returns its value, or `nil` when it has not finished
/// after `seconds`. Unlike a task group, this does not wait for an operation
/// that never finishes, so a wedged session fails the test instead of hanging it.
func browserReplWithDeadline<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    let box = BrowserReplOnceBox<T?>()
    return await withCheckedContinuation { continuation in
        box.set(continuation)
        Task { box.resume(await operation()) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            box.resume(nil)
        }
    }
}

/// Resumes a continuation once; later values are dropped.
final class BrowserReplOnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T?
    private var done = false

    func set(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if done, let early {
            lock.unlock()
            continuation.resume(returning: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        guard let continuation else {
            early = value
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// Suspends until the calling task is cancelled, and never resumes on its
/// own: work that never finishes, without a timer standing in for it.
func browserReplWaitUntilCancelled() async {
    let gate = BrowserReplCancellationGate()
    await withTaskCancellationHandler {
        await withCheckedContinuation { gate.park($0) }
    } onCancel: {
        gate.open()
    }
}

/// Holds a continuation until `open()`; one parked after `open()` resumes at once.
private final class BrowserReplCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func park(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow: Bool = lock.withLock {
            if opened { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func open() {
        let parked: CheckedContinuation<Void, Never>? = lock.withLock {
            opened = true
            defer { continuation = nil }
            return continuation
        }
        parked?.resume()
    }
}

/// The repository's `Resources/browser-repl` runtime, as the app bundles it.
func browserReplRepositoryBundle() throws -> BrowserReplRuntimeBundle {
    var directory = URL(fileURLWithPath: #filePath)
    // Tests/CmuxBrowserTests/Repl/<file> -> package -> Packages/macOS -> repository root.
    for _ in 0..<7 { directory.deleteLastPathComponent() }
    return try BrowserReplRuntimeBundle.load(from: directory.appendingPathComponent("Resources/browser-repl"))
}

/// A driver whose `slow` method waits until `release()` and records whether
/// its task was cancelled meanwhile; other methods behave like
/// `RecordingReplDriver`.
final class GatedReplDriver: BrowserReplDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var started: [CheckedContinuation<Void, Never>] = []
    private var startedCount = 0
    private(set) var cancelledAfterRelease: [Bool] = []
    private(set) var attachCount = 0
    private(set) var methods: [String] = []

    var capabilities: [String] { [] }

    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError> {
        lock.withLock { methods.append(method) }
        switch method {
        case "slow":
            let startedWaiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                startedCount += 1
                defer { started.removeAll() }
                return started
            }
            for waiter in startedWaiters { waiter.resume() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
            let cancelled = Task.isCancelled
            lock.withLock { cancelledAfterRelease.append(cancelled) }
            return .success("null")
        case "tabs.list":
            return .success(#"[{"targetId":"t1","title":"Fixture","url":"about:blank","active":true}]"#)
        case "cookies.get":
            return .success("[]")
        default:
            return .success("null")
        }
    }

    /// Returns once a `slow` call has started.
    func waitUntilSlowCallStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if startedCount > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                started.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }

    func attach(eventSink: @escaping BrowserReplDriverEventSink) {
        lock.withLock { attachCount += 1 }
    }

    func detach() {}
}

/// A working directory for test sessions. Not the temporary directory
/// itself: that holds every session's private storage (`cmux-browser-repl`)
/// and is refused as a REPL root.
let browserReplTestWorkingDirectory: String = {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-repl-test-cwd").path
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}()
