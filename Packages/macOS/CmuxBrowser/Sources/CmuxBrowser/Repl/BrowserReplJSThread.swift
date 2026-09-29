import CoreFoundation
import Foundation

/// A dedicated thread with a run loop that owns one JavaScriptCore context.
///
/// JavaScriptCore values are not thread-safe to share, so every access to a
/// session's `JSContext` is funneled through `perform(_:)`. Blocks run in
/// submission order, which keeps driver results, timer fires and events in
/// the order Swift produced them.
public final class BrowserReplJSThread: @unchecked Sendable {
    private let thread: Thread
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var isStopped = false

    /// Creates and starts the thread.
    /// - Parameter name: Thread name shown in crash reports and samples.
    public init(name: String) {
        let box = RunLoopBox()
        thread = Thread {
            box.set(CFRunLoopGetCurrent())
            // A port keeps `run(mode:before:)` from returning immediately
            // while no block is queued.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            box.started.signal()
            while !Thread.current.isCancelled {
                autoreleasepool {
                    _ = RunLoop.current.run(mode: .default, before: .distantFuture)
                }
            }
        }
        thread.name = name
        // JavaScriptCore needs more than the 512 KiB secondary-thread default
        // for deeply nested runtime code.
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
        box.started.wait()
        runLoop = box.get()
    }

    /// Runs `block` on the thread, after previously submitted blocks.
    /// Blocks submitted after `stop()` are dropped.
    /// - Returns: `false` when the thread has stopped and `block` will never run.
    @discardableResult
    public func perform(_ block: @escaping () -> Void) -> Bool {
        lock.lock()
        guard !isStopped, let runLoop else {
            lock.unlock()
            return false
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
        lock.unlock()
        return true
    }

    /// Runs `body` on the thread and waits for it. Must not be called on the thread itself.
    public func sync<T>(_ body: @escaping () -> T) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        var submitted = false
        lock.lock()
        if !isStopped, let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                box.value = body()
                done.signal()
            }
            CFRunLoopWakeUp(runLoop)
            submitted = true
        }
        lock.unlock()
        guard submitted else { return nil }
        done.wait()
        return box.value
    }

    /// Whether the caller is running on this thread.
    public var isCurrent: Bool {
        Thread.current === thread
    }

    /// Stops the run loop after queued blocks finish.
    public func stop() {
        lock.lock()
        guard !isStopped, let runLoop else {
            lock.unlock()
            return
        }
        isStopped = true
        let thread = self.thread
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            thread.cancel()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        lock.unlock()
    }
}

private final class RunLoopBox: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var runLoop: CFRunLoop?

    func set(_ value: CFRunLoop) {
        lock.lock()
        runLoop = value
        lock.unlock()
    }

    func get() -> CFRunLoop? {
        lock.lock()
        defer { lock.unlock() }
        return runLoop
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
